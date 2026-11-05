import AVKit
import Foundation
import ObjectiveC

/// 上游 GlobalRefresh-PiP 的「构造阶段隐藏控件」策略。
///
/// `AVPictureInPicturePlatformAdapter` 在 **创建 `AVPictureInPictureController` 的瞬间**
/// 会读取 `_proxyControlsStyle`。只有在这个窗口期返回 5，系统才会按「无控件」的参考样式
/// 建立本次 PiP 会话；构造完成后再用 KVC 写 `controlsStyle` 只能改后续控件，
/// 无法得到上游那种缩到 0.1pt 后完全看不见的效果。
///
/// 这里沿用上游做法：
/// - 仅在构造期间通过实例关联标记让 swizzled getter 返回 5；
/// - 构造结束立刻移除标记，不影响系统里其他 PiP；
/// - 运行时签名不匹配、或抓不到同一个 adapter 时返回 nil，
///   由调用方回退到普通构造，绝不带着不完整的策略启动。
enum PiPHiddenReferenceControls {
    private static var associationKey: UInt8 = 0
    private static var installed: Set<ObjectIdentifier> = []

    private typealias Getter = @convention(c) (AnyObject, Selector) -> Int

    /// 构造期间用来记录「这次构造碰到的 adapter」。
    private final class Construction {
        weak var adapter: NSObject?
        var hits = 0
    }
    private static var construction: Construction?

    /// 用隐藏参考样式创建 controller；返回 nil 表示当前系统不支持，调用方应回退。
    static func makeController(
        source: AVPictureInPictureController.ContentSource,
        log: (String) -> Void
    ) -> AVPictureInPictureController? {
        guard Thread.isMainThread else {
            log("隐藏控件构造跳过：不在主线程")
            return nil
        }
        guard let adapterClass = NSClassFromString("AVPictureInPicturePlatformAdapter") else {
            log("隐藏控件构造跳过：未找到系统适配类")
            return nil
        }
        guard construction == nil, install(adapterClass: adapterClass) else {
            log("隐藏控件构造跳过：内部方法签名不匹配")
            return nil
        }

        let context = Construction()
        construction = context
        defer { construction = nil }

        let controller = AVPictureInPictureController(contentSource: source)

        guard let captured = context.adapter, captured === platformAdapter(of: controller) else {
            if let captured = context.adapter { clear(adapter: captured) }
            log("隐藏控件构造未生效：没有抓到本次构造的适配对象")
            return nil
        }
        clear(adapter: captured)
        log("隐藏控件已按构造阶段样式 5 建立 · hits=\(context.hits)，构造结束后已释放")
        return controller
    }

    /// `AVPictureInPictureController` 的 `_platformAdapter` 只用于核对身份。
    private static func platformAdapter(of controller: AVPictureInPictureController) -> NSObject? {
        guard let cls = object_getClass(controller),
              let ivar = class_getInstanceVariable(cls, "_platformAdapter"),
              let encoding = ivar_getTypeEncoding(ivar), encoding.pointee == 64 else {
            return nil
        }
        return object_getIvar(controller, ivar) as? NSObject
    }

    private static func clear(adapter: NSObject) {
        objc_setAssociatedObject(adapter, &associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// 在 adapter 类上安装一次 `_proxyControlsStyle` 的 swizzle。
    private static func install(adapterClass: AnyClass) -> Bool {
        let key = ObjectIdentifier(adapterClass)
        if installed.contains(key) { return true }

        let selector = NSSelectorFromString("_proxyControlsStyle")
        guard let method = class_getInstanceMethod(adapterClass, selector),
              method_getNumberOfArguments(method) == 2 else {
            return false
        }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard String(cString: returnType) == "q" else { return false }

        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let block: @convention(block) (AnyObject) -> Int = { object in
            guard let target = object as? NSObject else {
                return original(object, selector)
            }
            if objc_getAssociatedObject(target, &associationKey) != nil { return 5 }
            if Thread.isMainThread, let context = construction {
                if context.adapter == nil {
                    context.adapter = target
                    objc_setAssociatedObject(
                        target,
                        &associationKey,
                        NSNumber(value: true),
                        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                    )
                }
                if context.adapter === target {
                    context.hits += 1
                    return 5
                }
            }
            return original(object, selector)
        }
        let replacement = imp_implementationWithBlock(block)
        if !class_addMethod(adapterClass, selector, replacement, method_getTypeEncoding(method)) {
            method_setImplementation(method, replacement)
        }
        installed.insert(key)
        return true
    }
}
