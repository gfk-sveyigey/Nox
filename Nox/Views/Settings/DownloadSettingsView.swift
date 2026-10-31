import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive
import NoxParsing
import NoxDownload
import NoxState

struct DownloadSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var localization = LocalizationManager.shared

    var body: some View {
        Form {
            Section {
                Picker(L("同时下载任务数"), selection: $appState.maxConcurrentDownloads) {
                    ForEach(AppState.maxConcurrentDownloadsOptions, id: \.self) { count in
                        Text(Self.concurrentTitle(count)).tag(count)
                    }
                }
                .onChange(of: appState.maxConcurrentDownloads) { _, _ in
                    appState.persist()
                }

                Picker(L("下载清晰度"), selection: $appState.preferredQuality) {
                    ForEach(PreferredQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .onChange(of: appState.preferredQuality) { _, _ in
                    appState.persist()
                }
            }

            Section {
                Picker(L("下载网络"), selection: $appState.downloadNetworkMode) {
                    ForEach(DownloadNetworkMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .onChange(of: appState.downloadNetworkMode) { _, _ in
                    appState.persist()
                }
            } footer: {
                Text(L("「仅无线局域网」不会使用蜂窝流量；更改对之后发起的请求生效。离开无线局域网后下载会中断，重新连接后点「继续下载」可从断点续传。"))
            }

            Section {
                Toggle(L("多线程下载"), isOn: $appState.experimentalMultiThreadDownload)
                    .onChange(of: appState.experimentalMultiThreadDownload) { _, _ in
                        appState.persist()
                    }

                if appState.experimentalMultiThreadDownload {
                    Picker(L("下载线程数"), selection: $appState.multiThreadSegmentCount) {
                        ForEach(Array(AppState.segmentCountRange), id: \.self) { count in
                            Text(String(count)).tag(count)
                        }
                    }
                    .onChange(of: appState.multiThreadSegmentCount) { _, _ in
                        appState.persist()
                    }
                }

                Picker(L("m3u8 分片并发"), selection: $appState.m3u8SegmentConcurrency) {
                    Text(L("跟随多线程设置")).tag(0)

                    ForEach(Array(AppState.m3u8ConcurrencyRange), id: \.self) { count in
                        if count > 0 {
                            Text(String(count)).tag(count)
                        }
                    }
                }
                .onChange(of: appState.m3u8SegmentConcurrency) { _, _ in
                    appState.persist()
                }
            } footer: {
                Text(L("把文件分成多个分片并行下载，可能提升速度。部分站点会限速或拒绝多连接，若出现下载失败请关闭此项。已开始的任务需要重试后才会按新设置重新分片。"))
            }
        }
        .navigationTitle(L("下载设置"))
        .navigationBarTitleDisplayMode(.inline)
    }

    static func concurrentTitle(_ count: Int) -> String {
        count == AppState.unlimitedConcurrentDownloads ? L("无限制") : String(count)
    }
}

/// 「后台保活」二级页：选择保活方式、保活模式、画中画窗口大小与共存兜底。
