import Foundation
import AVKit

/// 画中画「共存保护」：让本 App 的 PiP 与其他 App 的 PiP 尽量同时存在，
/// 减少互相挤掉、被抢占的情况。
///
/// ⚠️ 重要边界（沿用 GlobalRefresh-PiP 1.1.1 的风险说明，见 docs/DEVELOPMENT_PRD.md）：
/// - 这里用到的是**系统内部接口**（内部 adapter / `setContentType:` 一族），
///   不是 Apple 文档化的公开 API；上架有被拒风险，系统升级可能失效。
/// - 因此所有调用都先做**运行时能力与签名校验**，校验不通过就静默跳过，
///   绝不做未经校验的 `objc_msgSend`。
/// - 尤其**不做** `updatePlaybackStateUsingBlock:`：它的 block 参数个数 / 签名
///   无法在运行时可靠校验，一旦 ABI 不匹配会直接崩溃。宁可少一层适配，
///   也不冒险调用。
@MainActor
final class PiPCoexistenceProtection {

    /// 参考实现使用的两个内部取值：启动时用 4，启动成功后提交 6。
    /// 这两个数字是沿用的内部约定，**不要**当作 Apple 公布的枚举语义。
    private let initialContentType = 4
    private let coexistingContentType = 6

    private let controller: AVPictureInPictureController
    private var token = UUID()
    private var postStartTask: Task<Void, Never>?
    private var isPrepared = false

    var onLog: ((String) -> Void)?

    init(controller: AVPictureInPictureController) {
        self.controller = controller
    }

    /// 是否找到了可用的内部适配对象（找不到就只走公开 PiP，不报错）。
    var isSupported: Bool { isPrepared }

    // MARK: - 生命周期

    /// 构造阶段：定位内部适配对象并确认签名可用。
    func prepare() {
        guard let adapter = Self.internalAdapter(for: controller) else {
            onLog?("画中画共存保护：未找到内部适配对象，跳过（仅使用公开 PiP）")
            return
        }
        guard Self.canSetContentType(on: adapter) else {
            onLog?("画中画共存保护：内部签名不匹配，跳过")
            return
        }
        isPrepared = true
        submit(contentType: initialContentType)
    }

    /// `didStart` 之后延迟 1 秒提交一次共存类型。
    ///
    /// 延迟从「启动成功」开始计时，不会反复提交；期间会核对实例身份，
    /// 防止旧的延迟任务改到新的会话上。
    func schedulePostStartUpdate(for controller: AVPictureInPictureController) {
        guard isPrepared else { return }
        let token = self.token
        postStartTask?.cancel()
        postStartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, self.token == token else { return }
            guard self.controller === controller,
                  controller.isPictureInPictureActive,
                  let adapter = Self.internalAdapter(for: self.controller),
                  Self.canSetContentType(on: adapter)
            else { return }
            self.submit(contentType: self.coexistingContentType)
        }
    }

    /// 结束时使令牌失效、取消延迟任务，并尽量恢复初始类型。
    func restore() {
        token = UUID()
        postStartTask?.cancel()
        postStartTask = nil
        if isPrepared {
            submit(contentType: initialContentType)
        }
        isPrepared = false
    }

    // MARK: - 内部适配

    private func submit(contentType value: Int) {
        guard let adapter = Self.internalAdapter(for: controller),
              Self.canSetContentType(on: adapter)
        else { return }
        Self.setContentType(on: adapter, value: value)
    }

    /// 在 controller 上寻找系统的内部适配对象。
    /// 只按已知字段名匹配，且**只取对象类型（`@`）的 ivar**，
    /// 避免对非对象字段调用 `object_getIvar` 造成未定义行为。
    private static func internalAdapter(for controller: AVPictureInPictureController) -> AnyObject? {
        for name in ["platformAdapter", "pegasusProxy"] {
            if let value = objectValue(of: controller, named: name) {
                return value
            }
        }
        return nil
    }

    private static func objectValue(of object: AnyObject, named name: String) -> AnyObject? {
        var cls: AnyClass? = object_getClass(object)
        while let current = cls {
            if let ivar = class_getInstanceVariable(current, name),
               let encoding = ivar_getTypeEncoding(ivar),
               String(cString: encoding).hasPrefix("@") {
                if let value = object_getIvar(object, ivar) {
                    return value as AnyObject
                }
            }
            cls = class_getSuperclass(current)
        }
        return nil
    }

    /// 校验 `setContentType:` 存在、返回 void、且参数是整数。
    private static func canSetContentType(on object: AnyObject) -> Bool {
        let sel = NSSelectorFromString("setContentType:")
        guard let cls = object_getClass(object),
              let method = class_getInstanceMethod(cls, sel),
              let encoding = method_getTypeEncoding(method)
        else { return false }

        // 期望形如 v@:q / v@:i / v@:I / v@:Q —— void 返回，self + _cmd 之后是整数。
        let types = String(cString: encoding)
        guard types.hasPrefix("v@:") else { return false }
        let argument = String(types.dropFirst(3))
        return ["q", "i", "I", "Q", "l", "L"].contains(argument)
    }

    private static func setContentType(on object: AnyObject, value: Int) {
        let sel = NSSelectorFromString("setContentType:")
        guard let cls = object_getClass(object),
              let method = class_getInstanceMethod(cls, sel)
        else { return }
        typealias SetInt = @convention(c) (AnyObject, Selector, Int) -> Void
        let call = unsafeBitCast(method_getImplementation(method), to: SetInt.self)
        call(object, sel, value)
    }
}
