import SwiftUI
import UIKit

struct HistoryView: View {
    @EnvironmentObject private var appState: AppState
    let openInBrowser: (URL) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if appState.history.isEmpty {
                    ContentUnavailableView(
                        "暂无历史",
                        systemImage: "clock",
                        description: Text("打开过的视频页面会显示在这里。")
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
                                Text(item.visitedAt.formatted(date: .abbreviated, time: .shortened))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button {
                                    openInBrowser(item.url)
                                } label: {
                                    Label("跳转网页", systemImage: "safari")
                                }

                                Button {
                                    UIPasteboard.general.string = item.url.absoluteString
                                } label: {
                                    Label("复制链接", systemImage: "doc.on.doc")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    appState.removeHistory(item)
                                } label: {
                                    Label("删除记录", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("历史")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !appState.history.isEmpty {
                        Button("清空") {
                            appState.clearHistory()
                        }
                    }
                }
            }
        }
    }
}
