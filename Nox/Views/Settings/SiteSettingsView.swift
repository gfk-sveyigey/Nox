import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive
import NoxParsing
import NoxDownload
import NoxState

struct SiteSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var localization = LocalizationManager.shared

    var body: some View {
        Form {
            Section {
                ForEach(siteToggles) { site in
                    Toggle(site.title, isOn: siteBinding(for: site.id))
                }
            } footer: {
                Text(L("关闭后，对应网站的页面将无法解析，「解析视频」入口也会隐藏。"))
            }
        }
        .navigationTitle(L("解析来源"))
        .navigationBarTitleDisplayMode(.inline)
    }

    func siteBinding(for identifier: String) -> Binding<Bool> {
        Binding(
            get: { appState.isSiteEnabled(identifier) },
            set: { appState.setSite(identifier, enabled: $0) }
        )
    }

    /// 把解析器列表转成可 `ForEach` 的简单结构，
    /// 避免对 `any VideoSiteParser` 取 key path。
    var siteToggles: [SiteToggle] {
        VideoSiteParserRegistry.all.map {
            SiteToggle(id: $0.identifier, title: $0.displayName)
        }
    }

    struct SiteToggle: Identifiable {
        let id: String
        let title: String
    }
}

/// 「储存空间」里可单独统计与清理的类别。
enum StorageCategory: String, CaseIterable, Identifiable {
    case videos
    case parts
    case staging
    case networkCache
    case websiteData

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videos: return L("已下载视频")
        case .parts: return L("下载分片")
        case .staging: return L("临时文件")
        case .networkCache: return L("网络缓存")
        case .websiteData: return L("网站数据")
        }
    }

    var systemImage: String {
        switch self {
        case .videos: return "film"
        case .parts: return "square.split.2x2"
        case .staging: return "folder"
        case .networkCache: return "network"
        case .websiteData: return "globe"
        }
    }
}

/// 「储存空间」二级页：按类别展示占用。
///
/// 多选逻辑与「下载 / 历史」页保持一致：双指滑动进入多选，
/// 并沿滑动路径勾选类别，最后由右上角的「清理」统一清理。
