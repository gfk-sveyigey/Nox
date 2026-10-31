import Foundation
import NoxCore
import NoxDownload
import NoxParsing
import NoxState

/// 组装层：只有 App target 同时认识「具体状态类」与「引擎协议」。
///
/// 这样 `NoxDownload` / `NoxBrowser` 都不需要 import `NoxState`，
/// 依赖方向保持单向：Core ← 引擎 ← App。
@MainActor
extension AppState: DownloadStateStore, SiteAvailabilityProviding {}
