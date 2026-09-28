import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var openURL: URL?
    @State private var showingBrowser = false

    var body: some View {
        NavigationStack {
            Group {
                if appState.history.isEmpty {
                    ContentUnavailableView("暂无历史", systemImage: "clock", description: Text("打开过的视频页面会显示在这里。"))
                } else {
                    List {
                        ForEach(appState.history) { item in
                            Button {
                                openURL = item.url
                                showingBrowser = true
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.title).foregroundStyle(.primary).lineLimit(2)
                                    Text(item.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Text(item.visitedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) { appState.removeHistory(item) } label: { Label("删除", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("历史")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !appState.history.isEmpty { Button("清空") { appState.clearHistory() } }
                }
            }
            .sheet(isPresented: $showingBrowser) {
                if let url = openURL { SafariView(url: url) }
            }
        }
    }
}

import SafariServices
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
