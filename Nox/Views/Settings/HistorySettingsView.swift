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
                Picker(L("保留方式"), selection: $appState.historyRetentionMode) {
                    ForEach(HistoryRetentionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .onChange(of: appState.historyRetentionMode) { _, _ in
                    appState.applyHistoryRetention()
                    appState.persist()
                }

                switch appState.historyRetentionMode {
                case .count:
                    Picker(L("最大条数"), selection: $appState.historyRetentionCount) {
                        ForEach(AppState.historyCountOptions, id: \.self) { value in
                            Text(historyCountTitle(value)).tag(value)
                        }
                    }
                    .onChange(of: appState.historyRetentionCount) { _, _ in
                        appState.applyHistoryRetention()
                        appState.persist()
                    }
                case .days:
                    Picker(L("最多保留天数"), selection: $appState.historyRetentionDays) {
                        ForEach(AppState.historyDayOptions, id: \.self) { value in
                            Text(historyDayTitle(value)).tag(value)
                        }
                    }
                    .onChange(of: appState.historyRetentionDays) { _, _ in
                        appState.applyHistoryRetention()
                        appState.persist()
                    }
                }
            } footer: {
                Text(L("超出保留范围的历史记录会被自动删除。"))
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
