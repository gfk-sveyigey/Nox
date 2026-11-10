import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive
import NoxParsing
import NoxDownload
import NoxState

struct LogsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var manager: DownloadManager
    @ObservedObject var store = LogStore.shared
    @ObservedObject var localization = LocalizationManager.shared

    @State var showingClearConfirmation = false
    @State var shareFailureMessage: String?
    @State var showShareFailureAlert = false
    /// 首屏只渲染最近的若干条；滚到底部时再逐步展开/读取更早的日志。
    @State private var visibleCount = 100

    private static let pageSize = 100

    var body: some View {
        List {
            Section {
                Toggle(L("详细日志"), isOn: Binding(
                    get: { appState.verboseLogging },
                    set: { manager.setVerboseLogging($0) }
                ))
                SettingsPickerRow(
                    title: L("日志保留"),
                    selection: $store.retentionDays,
                    options: LogStore.retentionOptions.map {
                        SettingsPickerOption(value: $0, title: retentionTitle($0))
                    }
                )
            }

            Section {
                if store.entries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(L("暂无日志"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(visibleEntries) { entry in
                        logRow(entry)
                    }

                    if hasMoreEntries {
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .listRowSeparator(.hidden)
                        .task(id: loadMoreTrigger) {
                            await loadNextPage()
                        }
                    }
                }
            }
        }
        .navigationTitle(L("日志"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { export() } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(store.entries.isEmpty)
                .accessibilityLabel(L("导出日志"))
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(store.entries.isEmpty)
                .accessibilityLabel(L("清空日志"))
            }
        }
        .alert(L("清空日志？"), isPresented: $showingClearConfirmation) {
            Button(L("取消"), role: .cancel) {}
            Button(L("清空"), role: .destructive) { store.clear() }
        } message: {
            Text(L("所有日志将被删除，此操作无法撤销。"))
        }
        .alert(L("导出失败"), isPresented: $showShareFailureAlert) {
            Button(L("确定"), role: .cancel) {}
        } message: {
            Text(shareFailureMessage ?? L("无法导出日志"))
        }
    }

    func logRow(_ entry: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.level.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color(for: entry.level))
                Text(entry.date, format: .dateTime.year().month().day().hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(entry.message)
                .font(.footnote)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private var visibleEntries: [LogEntry] {
        Array(store.entries.reversed().prefix(visibleCount))
    }

    private var hasMoreEntries: Bool {
        visibleCount < store.entries.count || store.canLoadMore
    }

    /// 让底部加载行在展开一页或文件追加新块后重新触发。
    private var loadMoreTrigger: String {
        "\(visibleCount)-\(store.entries.count)-\(store.canLoadMore)"
    }

    @MainActor
    private func loadNextPage() async {
        // 略作停留，避免滚动惯性还没结束就连续展开多页。
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }

        if visibleCount < store.entries.count {
            visibleCount = min(visibleCount + Self.pageSize, store.entries.count)
        } else if store.canLoadMore {
            store.loadMore()
            visibleCount = min(visibleCount + Self.pageSize, store.entries.count)
        }
    }

    func retentionTitle(_ value: Int) -> String {
        value == 0 ? L("无限制") : String(format: L("%d 天"), value)
    }

    func color(for level: LogLevel) -> Color {
        switch level {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    /// contextMenu / 工具栏点击后同步 present 会被丢弃，延后一拍再弹分享面板。
    func export() {
        guard let url = store.exportFileURL() else {
            shareFailureMessage = L("无法导出日志")
            showShareFailureAlert = true
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            SharePresenter.present(items: [url])
        }
    }
}

/// Cookie 的读取 / 删除封装。
///
/// WKWebView 用的是持久化数据存储，登录状态（Cookie）本来就会跨启动保存；
/// 这里给设置页提供「查看 + 清理」的能力（换账号、怀疑登录态串了时用得上）。
