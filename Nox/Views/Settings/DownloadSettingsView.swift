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
    @ObservedObject var manager: DownloadManager

    init(manager: DownloadManager) {
        _manager = ObservedObject(wrappedValue: manager)
    }

    var body: some View {
        Form {
            Section {
                SettingsPickerRow(
                    title: L("同时下载任务数"),
                    selection: $appState.maxConcurrentDownloads,
                    options: AppState.maxConcurrentDownloadsOptions.map {
                        SettingsPickerOption(value: $0, title: Self.concurrentTitle($0))
                    }
                )
                .onChange(of: appState.maxConcurrentDownloads) { _, _ in
                    appState.persist()
                }

                SettingsPickerRow(
                    title: L("下载清晰度"),
                    selection: $appState.preferredQuality,
                    options: PreferredQuality.allCases.map {
                        SettingsPickerOption(value: $0, title: $0.title)
                    }
                )
                .onChange(of: appState.preferredQuality) { _, _ in
                    appState.persist()
                }
            }

            Section {
                SettingsPickerRow(
                    title: L("下载网络"),
                    selection: $appState.downloadNetworkMode,
                    options: DownloadNetworkMode.allCases.map {
                        SettingsPickerOption(value: $0, title: $0.title)
                    }
                )
                .onChange(of: appState.downloadNetworkMode) { _, _ in
                    appState.persist()
                }
            }

            Section {
                SettingsPickerRow(
                    title: L("最低剩余空间"),
                    selection: $appState.minFreeDiskSpace,
                    options: NoxDefaults.minFreeDiskSpaceOptions.map {
                        SettingsPickerOption(value: $0, title: Self.minFreeSpaceTitle($0))
                    }
                )
                .onChange(of: appState.minFreeDiskSpace) { _, _ in
                    appState.persist()
                    manager.reconcileQueue()
                }
            }

            Section {
                Toggle(L("多线程下载"), isOn: $appState.experimentalMultiThreadDownload)
                    .onChange(of: appState.experimentalMultiThreadDownload) { _, _ in
                        appState.persist()
                    }

                if appState.experimentalMultiThreadDownload {
                    SettingsPickerRow(
                        title: L("下载线程数"),
                        selection: $appState.multiThreadSegmentCount,
                        options: AppState.segmentCountRange.map {
                            SettingsPickerOption(value: $0, title: String($0))
                        }
                    )
                    .onChange(of: appState.multiThreadSegmentCount) { _, _ in
                        appState.persist()
                    }
                }

                SettingsPickerRow(
                    title: L("m3u8 分片并发"),
                    selection: $appState.m3u8SegmentConcurrency,
                    options: [SettingsPickerOption(value: 0, title: L("跟随多线程"))]
                        + AppState.m3u8ConcurrencyRange.filter { $0 > 0 }.map {
                            SettingsPickerOption(value: $0, title: String($0))
                        }
                )
                .onChange(of: appState.m3u8SegmentConcurrency) { _, _ in
                    appState.persist()
                }
            }
        }
        .settingsValueColumn()
        .navigationTitle(L("下载设置"))
        .navigationBarTitleDisplayMode(.inline)
    }

    static func concurrentTitle(_ count: Int) -> String {
        count == AppState.unlimitedConcurrentDownloads ? L("无限制") : String(count)
    }

    /// 储存保护选项用整数显示，避免 1 GiB 被格式化成「1.1 GB」。
    static func minFreeSpaceTitle(_ bytes: Int64) -> String {
        guard bytes > 0 else { return L("不限制") }

        if bytes % NoxDefaults.gigabyte == 0 {
            return "\(bytes / NoxDefaults.gigabyte) \(L("GB"))"
        }
        if bytes % NoxDefaults.megabyte == 0 {
            return "\(bytes / NoxDefaults.megabyte) \(L("MB"))"
        }
        return TransferStats.formattedSize(bytes)
    }
}

/// 「后台保活」二级页：选择保活方式、保活模式、画中画窗口大小与共存兜底。
