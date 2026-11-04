import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive
import NoxParsing
import NoxDownload
import NoxState

struct HistorySettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var localization = LocalizationManager.shared

    var body: some View {
        Form {
            Section {
                SettingsPickerRow(
                    title: L("保留方式"),
                    selection: $appState.historyRetentionMode,
                    options: HistoryRetentionMode.allCases.map {
                        SettingsPickerOption(value: $0, title: $0.title)
                    }
                )
                .onChange(of: appState.historyRetentionMode) { _, _ in
                    appState.applyHistoryRetention()
                    appState.persist()
                }

                switch appState.historyRetentionMode {
                case .count:
                    SettingsPickerRow(
                        title: L("最大条数"),
                        selection: $appState.historyRetentionCount,
                        options: AppState.historyCountOptions.map {
                            SettingsPickerOption(value: $0, title: historyCountTitle($0))
                        }
                    )
                    .onChange(of: appState.historyRetentionCount) { _, _ in
                        appState.applyHistoryRetention()
                        appState.persist()
                    }
                case .days:
                    SettingsPickerRow(
                        title: L("最多保留天数"),
                        selection: $appState.historyRetentionDays,
                        options: AppState.historyDayOptions.map {
                            SettingsPickerOption(value: $0, title: historyDayTitle($0))
                        }
                    )
                    .onChange(of: appState.historyRetentionDays) { _, _ in
                        appState.applyHistoryRetention()
                        appState.persist()
                    }
                }
            }

            Section {
                LabeledContent(L("当前记录"), value: String(appState.history.count))
            }
        }
        .navigationTitle(L("历史记录"))
        .navigationBarTitleDisplayMode(.inline)
    }

    func historyCountTitle(_ value: Int) -> String {
        value == AppState.unlimitedHistory ? L("无限制") : String(value)
    }

    func historyDayTitle(_ value: Int) -> String {
        value == AppState.unlimitedHistory ? L("无限制") : String(format: L("%d 天"), value)
    }
}

/// 「日志」二级页：查看 / 清空 / 导出运行日志。
