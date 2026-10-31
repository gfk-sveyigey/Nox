import Foundation

/// 判断某个站点是否被用户在设置里启用。
///
/// 由 App 层的 `AppState` 实现，解析模块不反向依赖状态类。
@MainActor
public protocol SiteAvailabilityProviding: AnyObject {
    func isSiteEnabled(_ identifier: String) -> Bool
}

/// 通用兜底嗅探器的站点标识。
///
/// 视图层用它判断「当前页面是不是靠嗅探兜底」，因此单独公开；
/// 具体的解析器实现仍然保持模块内可见。
public enum SnifferSite {
    public static let identifier = "generic"
}
