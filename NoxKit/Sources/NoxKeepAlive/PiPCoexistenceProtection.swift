import AVFoundation
import AVKit
import Foundation
import ObjectiveC
import NoxCore

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
/// 2. **启动前就用 6**：系统的 `willShow` 阶段会依据新会话的内容类型决定是否允许
///    与已有画中画共存；等到 `didStart` 之后再改成 6 已经太晚，另一个 App 的画中画
///    在启动瞬间就已经被挤掉了。
final class PiPCoexistenceProtection {

    private typealias IntegerSetter = @convention(c) (AnyObject, Selector, Int) -> Void
    private typealias IntegerGetter = @convention(c) (AnyObject, Selector) -> Int
    private typealias ObjectGetter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    private typealias RespondsGetter = @convention(c) (AnyObject, Selector, Selector) -> Bool
    private typealias StateMutation = @convention(block) (AnyObject) -> Void
    private typealias StateUpdater = @convention(c) (AnyObject, Selector, StateMutation) -> Void

    /// 内部内容类型取值：6 是系统允许「与已有画中画共存」的类型，4 是普通视频类型。
    /// 这两个数字是沿用的内部约定，**不要**当作 Apple 公布的枚举语义。
    ///
    /// 关键：类型必须在 `startPictureInPicture()` **之前**就提交为 6。
    /// 系统在 `willShow` 时就会检查新会话的类型（`canActivateUntetheredAlongsideOtherObject:`），
    /// 等到 `didStart` 后再改 6 已经来不及，另一个 App 的画中画已经被取消。
    private let coexistingContentType = 6
    /// 退场时恢复的普通类型。
    private let fallbackContentType = 4
    /// `didStart` 之后再次提交共存类型的延迟（只做一次确认，不轮询）。
    private let postStartDelay: TimeInterval = 1

    private static var associationKey: UInt8 = 0
    private static var installedClasses: Set<ObjectIdentifier> = []

    /// provider 的实例级状态，挂在 adapter 上，供类方法回调读取。
    private final class Configuration {
        weak var proxy: NSObject?
        /// 系统可能从任意线程查询内容类型，读写都走锁。
        private let lock = NSLock()
        private var storedProvidedType: Int
        /// 正处于「惰性取得 proxy」的过程中，provider 借此机会补记 proxy 身份。
        var isObtainingProxy = false
        private var callCount = 0

        func recordProviderCall() -> Int {
            lock.lock()
            defer { lock.unlock() }
            callCount += 1
            return callCount
        }

        init(proxy: NSObject?, providedType: Int) {
            self.proxy = proxy
            self.storedProvidedType = providedType
        }

        var providedType: Int {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedProvidedType
            }
            set {
                lock.lock()
                storedProvidedType = newValue
                lock.unlock()
            }
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
    /// prepare 失败只提示一次，避免重试时刷屏。
    private var hasReportedPrepareFailure = false

    init(controller: AVPictureInPictureController) {
        self.controller = controller
    }

    /// 是否找到了可用的内部适配对象并安装好 provider（找不到就只走公开 PiP，不报错）。
    var isSupported: Bool { isPrepared }

    /// 详细诊断日志开关，由画中画保活同步。
    var verboseLogging = false

    private func verboseLog(_ message: @autoclosure () -> String) {
        guard verboseLogging else { return }
        noxKeepAliveLog("画中画共存保护（诊断）：\(message())")
    }

    // MARK: - 生命周期

    /// 构造阶段：定位内部适配对象，**先装 provider 再取 proxy**，最后校验签名并提交初始类型。
    func prepare() {
        verboseLog("prepare 开始")
        guard Thread.isMainThread else {
            verboseLog("prepare 跳过：不在主线程")
            return
        }
        // 会话已经在运行时**绝不能**重新安装 / 重设内容类型：那会把已经切到共存
        // 类型的活动会话改回 4，系统随后就会把别的 App 的画中画挤掉。
        guard !controller.isPictureInPictureActive else {
            verboseLog("prepare 跳过：画中画已在运行")
            return
        }
        guard !isPrepared else {
            verboseLog("prepare 跳过：本次会话已安装")
            return
        }
        guard let adapter = Self.object(controller, selector: "platformAdapter"),
              let base = object_getClass(adapter),
              Self.addScopedProvider(to: base) else {
            verboseLog("prepare 失败：未找到 adapter 或 provider 安装失败")
            reportPrepareFailureOnce("未找到内部适配对象，跳过（仅使用公开画中画）")
            return
        }

        verboseLog("找到 adapter · \(String(describing: type(of: adapter)))")
        // 关键顺序：provider 与其初始值必须在**惰性取得 pegasusProxy 之前**就位。
        // 系统在创建 proxy 时会依据实例响应能力 / 内容类型决定实现；
        // 先取 proxy 再装 provider，会让本次会话仍是普通 PiP ——
        // 表现就是「启动保活时把其他 App 的画中画挤掉」。
        // 从 provider 第一次被查询起就返回 6，保证系统在 willShow 前看到共存类型。
        let configuration = Configuration(proxy: nil, providedType: coexistingContentType)
        objc_setAssociatedObject(adapter, &Self.associationKey, configuration, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        configuration.isObtainingProxy = true
        let candidateProxy = Self.object(adapter, selector: "pegasusProxy")
        configuration.isObtainingProxy = false
        verboseLog("取得 pegasusProxy · \(candidateProxy.map { String(describing: type(of: $0)) } ?? "nil")")

        guard let proxy = candidateProxy,
              let expected = NSClassFromString("PGPictureInPictureProxy"),
              proxy.isKind(of: expected),
              configuration.proxy == nil || configuration.proxy === proxy else {
            objc_setAssociatedObject(adapter, &Self.associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            reportPrepareFailureOnce("未找到内部代理对象，跳过（仅使用公开画中画）")
            return
        }
        configuration.proxy = proxy

        verboseLog("校验内部签名并安装 provider · proxy=\(String(describing: type(of: proxy)))")
        guard install(adapter: adapter, proxy: proxy, configuration: configuration) else {
            objc_setAssociatedObject(adapter, &Self.associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            reportPrepareFailureOnce("内部签名不匹配，跳过（仅使用公开画中画）")
            return
        }
        isPrepared = true
        hasReportedPrepareFailure = false
        verboseLog("prepare 完成 · provider 已安装")
    }

    private func reportPrepareFailureOnce(_ message: String) {
        guard !hasReportedPrepareFailure else { return }
        hasReportedPrepareFailure = true
        noxKeepAliveLog("画中画共存保护：\(message)")
    }

    /// `didStart` 之后延迟一小段提交一次共存类型。
    ///
    /// 延迟从「启动成功」开始计时，不会反复提交；期间会核对实例身份，
    /// 防止旧的延迟任务改到新的会话上。
    func schedulePostStartUpdate(for controller: AVPictureInPictureController) {
        verboseLog("schedulePostStartUpdate · active=\(controller.isPictureInPictureActive) suspended=\(controller.isPictureInPictureSuspended) possible=\(controller.isPictureInPicturePossible)")
        guard Thread.isMainThread else {
            verboseLog("跳过启动后提交：不在主线程")
            return
        }
        guard isPrepared, configuration != nil else {
            noxKeepAliveLog("画中画共存保护：未安装 provider，跳过启动后提交")
            verboseLog("跳过启动后提交：provider 未安装")
            return
        }
        guard !postStartScheduled else {
            verboseLog("跳过启动后提交：本次会话已安排过")
            return
        }
        guard self.controller === controller else {
            noxKeepAliveLog("画中画共存保护：controller 身份不一致，跳过启动后提交")
            verboseLog("跳过启动后提交：controller 身份不一致")
            return
        }
        guard controller.isPictureInPictureActive else {
            noxKeepAliveLog("画中画共存保护：didStart 时 PiP 未处于激活状态，跳过启动后提交")
            verboseLog("跳过启动后提交：PiP 未激活")
            return
        }
        postStartScheduled = true
        noxKeepAliveLog("画中画共存保护：已安排 \(postStartDelay) 秒后提交共存类型")
        let token = installationID
        DispatchQueue.main.asyncAfter(deadline: .now() + postStartDelay) { [weak self] in
            guard let self else { return }
            guard self.installationID == token else {
                self.verboseLog("启动后提交已取消：会话令牌已失效")
                return
            }
            guard self.controller === controller, controller.isPictureInPictureActive,
                  !controller.isPictureInPictureSuspended,
                  let adapter = Self.object(controller, selector: "platformAdapter"),
                  let proxy = Self.object(adapter, selector: "pegasusProxy"),
                  adapter === self.adapter, proxy === self.proxy else {
                noxKeepAliveLog("画中画共存保护：启动后核验失败，跳过共存类型提交")
                self.verboseLog("启动后核验失败 · active=\(controller.isPictureInPictureActive) suspended=\(controller.isPictureInPictureSuspended)")
                return
            }
            self.verboseLog("启动后核验通过，提交共存内容类型")
            self.submitCoexistingType()
        }
    }

    /// 结束时使令牌失效、清理实例关联配置，并尽量恢复初始类型。
    func restore() {
        let currentType = proxy.flatMap { Self.contentType(of: $0) }.map(String.init) ?? "nil"
        verboseLog("restore 开始 · adapter=\(adapter != nil) proxy=\(proxy != nil) contentType=\(currentType)")
        installationID = nil
        postStartScheduled = false
        isPrepared = false
        hasReportedPrepareFailure = false
        defer {
            adapter = nil
            proxy = nil
            configuration = nil
            originalContentType = nil
        }
        guard let adapter else {
            verboseLog("restore 跳过：adapter 已释放")
            return
        }
        objc_setAssociatedObject(adapter, &Self.associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if let proxy, let previous = originalContentType, Self.contentType(of: proxy) == coexistingContentType,
           let state = Self.object(proxy, selector: "playbackState"),
           let stateClass = object_getClass(state),
           let setter = Self.method(stateClass, selector: NSSelectorFromString("setContentType:"), result: "v", arguments: ["q"]) {
            let setterIMP = unsafeBitCast(method_getImplementation(setter), to: IntegerSetter.self)
            setterIMP(state, NSSelectorFromString("setContentType:"), previous)
            verboseLog("restore 已恢复 contentType=\(previous)")
        } else {
            verboseLog("restore 未恢复 contentType（当前不是共存类型或运行时不可用）")
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
              previousType == coexistingContentType || previousType == fallbackContentType else {
            verboseLog("install 失败：内部签名或 contentType 不匹配")
            return false
        }

        let token = UUID()
        self.configuration = configuration
        installationID = token
        // 上一次会话可能没来得及把 6 退回 4（例如 App 被挂起后直接重开）。
        // 这种情况下仍可继续安装，但退场时要回到标准的 4，而不是 6。
        originalContentType = previousType == coexistingContentType ? fallbackContentType : previousType
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
        noxKeepAliveLog("画中画共存保护：已安装 provider（启动前即类型 6，本地 contentType=\(localType)）")
        verboseLog("install 成功 · previousType=\(previousType) localType=\(localType)")
        return true
    }

    /// 启动前把内容类型再提交一次（6）。
    ///
    /// 仅靠构造阶段的一次提交不够：App 冷启动时 XPC 连接可能还没建立，
    /// 中间几十秒的播放状态更新也可能把类型改回 4。因此在
    /// `startPictureInPicture()` 前再提交一次，保证系统在 `willShow`
    /// 决策前看到共存类型。
    func prepareForStart() {
        guard Thread.isMainThread, isPrepared, configuration != nil,
              !controller.isPictureInPictureActive else { return }
        submitContentType(coexistingContentType, quiet: true)
    }

    /// `didStart` 后再次确认共存类型（6）。
    ///
    /// 启动前已经提交过 6；这里只做一次确认，保证启动过程中即使有其他播放状态
    /// 更新也不会把类型退回普通值。
    func confirmCoexistenceType(for controller: AVPictureInPictureController) {
        guard Thread.isMainThread, isPrepared, configuration != nil,
              self.controller === controller, controller.isPictureInPictureActive else { return }
        submitContentType(coexistingContentType)
    }

    /// 启动成功后提交共存类型 6（一次）。
    private func submitCoexistingType() {
        submitContentType(coexistingContentType)
    }

    /// 提交一次内容类型。只走校验过的 `updatePlaybackStateUsingBlock:`。
    private func submitContentType(_ type: Int, quiet: Bool = false) {
        let updateSelector = NSSelectorFromString("updatePlaybackStateUsingBlock:")
        let setterSelector = NSSelectorFromString("setContentType:")
        guard let adapter, let proxy, let configuration, let token = installationID,
              let proxyClass = object_getClass(proxy),
              let update = Self.method(proxyClass, selector: updateSelector, result: "v", arguments: ["@?"]),
              let state = Self.object(proxy, selector: "playbackState"),
              let stateClass = object_getClass(state),
              let setter = Self.method(stateClass, selector: setterSelector, result: "v", arguments: ["q"]) else {
            noxKeepAliveLog("画中画共存保护：提交内容类型 \(type) 被跳过（运行时不支持）")
            verboseLog("提交内容类型失败：运行时签名不支持 · type=\(type)")
            return
        }

        let previousLocalType = Self.contentType(of: proxy)
        configuration.providedType = type
        let setterIMP = unsafeBitCast(method_getImplementation(setter), to: IntegerSetter.self)
        let mutation: StateMutation = { [weak self, weak adapter] currentState in
            guard let self, self.installationID == token, let adapter,
                  (objc_getAssociatedObject(adapter, &Self.associationKey) as? Configuration) === configuration,
                  object_getClass(currentState) === stateClass else { return }
            setterIMP(currentState, setterSelector, type)
        }
        unsafeBitCast(method_getImplementation(update), to: StateUpdater.self)(proxy, updateSelector, mutation)
        let localType = Self.contentType(of: proxy).map(String.init) ?? "unknown"
        if !quiet || previousLocalType != type {
            noxKeepAliveLog("画中画共存保护：已提交内容类型 \(type)（本地 contentType=\(localType)）")
        }
        verboseLog("提交内容类型完成 · type=\(type) localType=\(localType) quiet=\(quiet)")
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
            if configuration.recordProviderCall() == 1 {
                noxKeepAliveLog("画中画共存保护：系统已查询内容类型（返回 \(configuration.providedType)）")
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
