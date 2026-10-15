import AVFoundation
import AVKit
import Foundation
import ObjectiveC

/// 保活诊断出口。
///
/// 画中画共存保护运行在任意线程（系统回调），不能直接碰 `@MainActor` 的 `LogStore`，
/// 这里显式跳回主线程写日志。
func noxKeepAliveLog(_ message: String) {
    Task { @MainActor in LogStore.shared.info(message) }
}

/// 画中画「共存保护」：让本 App 的 PiP 与其他 App 的 PiP 尽量同时存在，
/// 减少互相挤掉、被抢占的情况。
///
/// ⚠️ 重要边界（沿用 GlobalRefresh-PiP 1.1.1 的风险说明，见 docs/DEVELOPMENT_PRD.md）：
/// - 这里用到的是**系统内部接口**（内部 adapter / `pegasusProxy` / `playbackState` / `setContentType:` 一族），
///   不是 Apple 文档化的公开 API；上架有被拒风险，系统升级可能失效。
/// - 因此所有调用都先做**运行时能力与签名校验**，校验不通过就静默跳过，
///   绝不做未经校验的 `objc_msgSend`。
/// - 尤其**不做** `updatePlaybackStateUsingBlock:` 之外的未校验调用：它的 block 参数
///   签名会先用 `method(_:selector:result:arguments:)` 校验（`v@:@?`），校验不过就跳过。
///
/// 机制（对齐参考实现 PiPCoexistenceExperiment）：
/// 1. **先**在 adapter 类上安装实例级 provider `pictureInPictureProxyContentType:` 并挂上实例配置，
///    **再**惰性取得 `pegasusProxy` —— 系统在创建 proxy 时会依据响应能力 / 内容类型决定实现，
///    顺序反了这次会话就仍是普通 PiP（表现为启动保活时把其他 App 的画中画挤掉）；
/// 2. 首次启动用 4，`didStart` 后延迟一小段（当前 0.3 秒）提交 6（一次，不轮询）。
final class PiPCoexistenceProtection {

    private typealias IntegerSetter = @convention(c) (AnyObject, Selector, Int) -> Void
    private typealias IntegerGetter = @convention(c) (AnyObject, Selector) -> Int
    private typealias ObjectGetter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    private typealias RespondsGetter = @convention(c) (AnyObject, Selector, Selector) -> Bool
    private typealias StateMutation = @convention(block) (AnyObject) -> Void
    private typealias StateUpdater = @convention(c) (AnyObject, Selector, StateMutation) -> Void

    /// 参考实现使用的两个内部取值：启动时用 4，启动成功后提交 6。
    /// 这两个数字是沿用的内部约定，**不要**当作 Apple 公布的枚举语义。
    private let initialContentType = 4
    private let coexistingContentType = 6
    /// `didStart` 之后延迟提交共存类型的时长。
    private let postStartDelay: TimeInterval = 0.3

    private static var associationKey: UInt8 = 0
    private static var installedClasses: Set<ObjectIdentifier> = []

    /// provider 的实例级状态，挂在 adapter 上，供类方法回调读取。
    private final class Configuration {
        weak var proxy: NSObject?
        var providedType: Int
        /// 正处于「惰性取得 proxy」的过程中，provider 借此机会补记 proxy 身份。
        var isObtainingProxy = false

        init(proxy: NSObject?, providedType: Int) {
            self.proxy = proxy
            self.providedType = providedType
        }
    }

    private let controller: AVPictureInPictureController
    private weak var adapter: NSObject?
    private weak var proxy: NSObject?
    private var configuration: Configuration?
    private var originalContentType: Int?
    private var installationID: UUID?
    private var postStartScheduled = false
    private var isPrepared = false

    init(controller: AVPictureInPictureController) {
        self.controller = controller
    }

    /// 是否找到了可用的内部适配对象并安装好 provider（找不到就只走公开 PiP，不报错）。
    var isSupported: Bool { isPrepared }

    // MARK: - 生命周期

    /// 构造阶段：定位内部适配对象，**先装 provider 再取 proxy**，最后校验签名并提交初始类型。
    func prepare() {
        guard Thread.isMainThread else { return }
        guard let adapter = Self.object(controller, selector: "platformAdapter"),
              let base = object_getClass(adapter),
              Self.addScopedProvider(to: base) else {
            noxKeepAliveLog("画中画共存保护：未找到内部适配对象，跳过（仅使用公开 PiP）")
            return
        }

        // 关键顺序：provider 与其初始值必须在**惰性取得 pegasusProxy 之前**就位。
        // 系统在创建 proxy 时会依据实例响应能力 / 内容类型决定实现；
        // 先取 proxy 再装 provider，会让本次会话仍是普通 PiP ——
        // 表现就是「启动保活时把其他 App 的画中画挤掉」。
        let configuration = Configuration(proxy: nil, providedType: initialContentType)
        objc_setAssociatedObject(adapter, &Self.associationKey, configuration, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        configuration.isObtainingProxy = true
        let candidateProxy = Self.object(adapter, selector: "pegasusProxy")
        configuration.isObtainingProxy = false

        guard let proxy = candidateProxy,
              let expected = NSClassFromString("PGPictureInPictureProxy"),
              proxy.isKind(of: expected),
              configuration.proxy == nil || configuration.proxy === proxy else {
            objc_setAssociatedObject(adapter, &Self.associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            noxKeepAliveLog("画中画共存保护：未找到内部代理对象，跳过（仅使用公开 PiP）")
            return
        }
        configuration.proxy = proxy

        guard install(adapter: adapter, proxy: proxy, configuration: configuration) else {
            objc_setAssociatedObject(adapter, &Self.associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            noxKeepAliveLog("画中画共存保护：内部签名不匹配，跳过（仅使用公开 PiP）")
            return
        }
        isPrepared = true
    }

    /// `didStart` 之后延迟一小段提交一次共存类型。
    ///
    /// 延迟从「启动成功」开始计时，不会反复提交；期间会核对实例身份，
    /// 防止旧的延迟任务改到新的会话上。
    func schedulePostStartUpdate(for controller: AVPictureInPictureController) {
        guard Thread.isMainThread else { return }
        guard isPrepared, configuration != nil else {
            noxKeepAliveLog("画中画共存保护：未安装 provider，跳过启动后提交")
            return
        }
        guard !postStartScheduled else { return }
        guard self.controller === controller else {
            noxKeepAliveLog("画中画共存保护：controller 身份不一致，跳过启动后提交")
            return
        }
        guard controller.isPictureInPictureActive else {
            noxKeepAliveLog("画中画共存保护：didStart 时 PiP 未处于激活状态，跳过启动后提交")
            return
        }
        postStartScheduled = true
        noxKeepAliveLog("画中画共存保护：已安排 \(postStartDelay) 秒后提交共存类型")
        let token = installationID
        DispatchQueue.main.asyncAfter(deadline: .now() + postStartDelay) { [weak self] in
            guard let self, self.installationID == token else { return }
            guard self.controller === controller, controller.isPictureInPictureActive,
                  !controller.isPictureInPictureSuspended,
                  let adapter = Self.object(controller, selector: "platformAdapter"),
                  let proxy = Self.object(adapter, selector: "pegasusProxy"),
                  adapter === self.adapter, proxy === self.proxy else {
                noxKeepAliveLog("画中画共存保护：启动后核验失败，跳过共存类型提交")
                return
            }
            self.submitCoexistingType()
        }
    }

    /// 结束时使令牌失效、清理实例关联配置，并尽量恢复初始类型。
    func restore() {
        installationID = nil
        postStartScheduled = false
        isPrepared = false
        defer {
            adapter = nil
            proxy = nil
            configuration = nil
            originalContentType = nil
        }
        guard let adapter else { return }
        objc_setAssociatedObject(adapter, &Self.associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if let proxy, let previous = originalContentType, Self.contentType(of: proxy) == coexistingContentType,
           let state = Self.object(proxy, selector: "playbackState"),
           let stateClass = object_getClass(state),
           let setter = Self.method(stateClass, selector: NSSelectorFromString("setContentType:"), result: "v", arguments: ["q"]) {
            let setterIMP = unsafeBitCast(method_getImplementation(setter), to: IntegerSetter.self)
            setterIMP(state, NSSelectorFromString("setContentType:"), previous)
        }
    }

    // MARK: - 安装与提交

    /// 校验运行时可用的内部签名，登记实例配置，并把首次提交（内容类型 4）挂到播放状态更新上。
    private func install(adapter candidate: NSObject, proxy candidateProxy: NSObject, configuration: Configuration) -> Bool {
        guard Thread.isMainThread else { return false }

        let updateSelector = NSSelectorFromString("updatePlaybackStateUsingBlock:")
        let setterSelector = NSSelectorFromString("setContentType:")
        guard let proxyClass = object_getClass(candidateProxy),
              let update = Self.method(proxyClass, selector: updateSelector, result: "v", arguments: ["@?"]),
              let state = Self.object(candidateProxy, selector: "playbackState"),
              let stateClass = object_getClass(state),
              let setter = Self.method(stateClass, selector: setterSelector, result: "v", arguments: ["q"]),
              let previousType = Self.contentType(of: candidateProxy),
              previousType == initialContentType else {
            return false
        }

        let token = UUID()
        self.configuration = configuration
        installationID = token
        originalContentType = previousType
        adapter = candidate
        proxy = candidateProxy
        // 关联配置已在 prepare() 里挂好（必须早于 proxy 创建），这里不再重复设置。

        let setterIMP = unsafeBitCast(method_getImplementation(setter), to: IntegerSetter.self)
        let mutation: StateMutation = { [weak self, weak candidate] currentState in
            guard let self, self.installationID == token, let candidate,
                  (objc_getAssociatedObject(candidate, &Self.associationKey) as? Configuration) === configuration,
                  object_getClass(currentState) === stateClass else { return }
            setterIMP(currentState, setterSelector, configuration.providedType)
        }
        unsafeBitCast(method_getImplementation(update), to: StateUpdater.self)(candidateProxy, updateSelector, mutation)
        let localType = Self.contentType(of: candidateProxy).map(String.init) ?? "unknown"
        noxKeepAliveLog("画中画共存保护：已安装 provider（首次类型 4，启动后转 6，本地 contentType=\(localType)）")
        return true
    }

    /// 启动成功后提交共存类型 6（一次）。
    private func submitCoexistingType() {
        let updateSelector = NSSelectorFromString("updatePlaybackStateUsingBlock:")
        let setterSelector = NSSelectorFromString("setContentType:")
        guard let adapter, let proxy, let configuration, let token = installationID,
              let proxyClass = object_getClass(proxy),
              let update = Self.method(proxyClass, selector: updateSelector, result: "v", arguments: ["@?"]),
              let state = Self.object(proxy, selector: "playbackState"),
              let stateClass = object_getClass(state),
              let setter = Self.method(stateClass, selector: setterSelector, result: "v", arguments: ["q"]) else {
            noxKeepAliveLog("画中画共存保护：启动后提交被跳过（运行时不支持）")
            return
        }

        configuration.providedType = coexistingContentType
        let setterIMP = unsafeBitCast(method_getImplementation(setter), to: IntegerSetter.self)
        let mutation: StateMutation = { [weak self, weak adapter] currentState in
            guard let self, self.installationID == token, let adapter,
                  (objc_getAssociatedObject(adapter, &Self.associationKey) as? Configuration) === configuration,
                  object_getClass(currentState) === stateClass else { return }
            setterIMP(currentState, setterSelector, self.coexistingContentType)
        }
        unsafeBitCast(method_getImplementation(update), to: StateUpdater.self)(proxy, updateSelector, mutation)
        let localType = Self.contentType(of: proxy).map(String.init) ?? "unknown"
        noxKeepAliveLog("画中画共存保护：已提交共存内容类型 6（本地 contentType=\(localType)）")
    }

    // MARK: - 运行时校验

    /// 在 adapter 类上安装**实例级** provider，并 hook `respondsToSelector:`。
    ///
    /// - provider 只对挂了关联配置的实例返回共存值，其他实例继续走原实现；
    /// - 类级方法一旦装上就摘不掉（参考实现同样如此），所以用静态集合去重，
    ///   未参与时保持休眠。
    private static func addScopedProvider(to base: AnyClass) -> Bool {
        let providerSelector = NSSelectorFromString("pictureInPictureProxyContentType:")
        let respondsSelector = NSSelectorFromString("respondsToSelector:")
        let key = ObjectIdentifier(base)
        if installedClasses.contains(key) { return true }

        guard let responds = method(base, selector: respondsSelector, result: "B", arguments: [":"]) else { return false }
        let encoding = method_getTypeEncoding(responds)
        let originalResponds = unsafeBitCast(method_getImplementation(responds), to: RespondsGetter.self)

        let responseBlock: @convention(block) (AnyObject, Selector) -> Bool = { object, selector in
            if selector == providerSelector {
                return (objc_getAssociatedObject(object, &associationKey) as? Configuration) != nil
            }
            return originalResponds(object, respondsSelector, selector)
        }
        let providerBlock: @convention(block) (AnyObject, AnyObject?) -> Int = { object, queriedProxy in
            guard let configuration = objc_getAssociatedObject(object, &associationKey) as? Configuration else {
                return (queriedProxy as? NSObject).flatMap { contentType(of: $0) } ?? 4
            }
            // 惰性取得 proxy 的这一次调用：把 queriedProxy 记成当前会话的代理。
            if configuration.proxy == nil, configuration.isObtainingProxy, Thread.isMainThread,
               let queried = queriedProxy as? NSObject {
                configuration.proxy = queried
            }
            guard let proxy = configuration.proxy, queriedProxy === proxy else {
                return (queriedProxy as? NSObject).flatMap { contentType(of: $0) } ?? 4
            }
            return configuration.providedType
        }

        let providerIMP = imp_implementationWithBlock(providerBlock)
        guard class_addMethod(base, providerSelector, providerIMP, "q@:@") else {
            imp_removeBlock(providerIMP)
            return false
        }
        if let encoding {
            class_replaceMethod(base, respondsSelector, imp_implementationWithBlock(responseBlock), encoding)
        }
        installedClasses.insert(key)
        return true
    }

    /// 取 `playbackState.contentType`（内部对象上的整数属性）。
    private static func contentType(of proxy: NSObject) -> Int? {
        guard let state = object(proxy, selector: "playbackState"), let type = object_getClass(state),
              let getter = method(type, selector: NSSelectorFromString("contentType"), result: "q") else { return nil }
        return unsafeBitCast(method_getImplementation(getter), to: IntegerGetter.self)(state, NSSelectorFromString("contentType"))
    }

    /// 按 selector 取对象返回值（校验返回值是对象类型）。
    private static func object(_ owner: NSObject, selector name: String) -> NSObject? {
        let selector = NSSelectorFromString(name)
        guard let type = object_getClass(owner), let method = method(type, selector: selector, result: "@") else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: ObjectGetter.self)(owner, selector)?.takeUnretainedValue() as? NSObject
    }

    /// 校验方法存在、参数个数、返回值与各参数类型都与预期一致。
    private static func method(_ type: AnyClass, selector: Selector, result: String, arguments: [String] = []) -> Method? {
        guard let method = class_getInstanceMethod(type, selector),
              method_getNumberOfArguments(method) == arguments.count + 2 else { return nil }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard String(cString: returnType) == result else { return nil }
        for (index, expected) in arguments.enumerated() {
            guard let type = method_copyArgumentType(method, UInt32(index + 2)) else { return nil }
            let actual = String(cString: type)
            free(type)
            guard actual == expected else { return nil }
        }
        return method
    }
}
