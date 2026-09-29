import SwiftUI
import UIKit

struct HistoryView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared
    @State private var showingClearConfirmation = false

    let openInBrowser: (URL) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if appState.history.isEmpty {
                    ContentUnavailableView(
                        L("暂无历史"),
                        systemImage: "clock",
                        description: Text(L("打开过的视频页面会显示在这里。"))
                    )
                } else {
                    List {
                        ForEach(appState.history) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Text(item.url.absoluteString)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                // Text(_:format:) 会走 .environment(\.locale)，
                                // Date.formatted() 不会，所以日期也跟着 App 语言变
                                Text(item.visitedAt, format: .dateTime.year().month().day().hour().minute())
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button {
                                    openInBrowser(item.url)
                                } label: {
                                    Label(L("跳转网页"), systemImage: "safari")
                                }

                                Button {
                                    UIPasteboard.general.string = item.url.absoluteString
                                } label: {
                                    Label(L("复制链接"), systemImage: "doc.on.doc")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    appState.removeHistory(item)
                                } label: {
                                    Label(L("删除记录"), systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L("历史"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !appState.history.isEmpty {
                        Button(L("清空")) {
                            showingClearConfirmation = true
                        }
                    }
                }
            }
            .alert(L("清空历史记录？"), isPresented: $showingClearConfirmation) {
                Button(L("取消"), role: .cancel) {}
                Button(L("清空"), role: .destructive) {
                    appState.clearHistory()
                }
            } message: {
                Text(L("所有浏览历史将被删除，此操作无法撤销。"))
            }
        }
    }
}