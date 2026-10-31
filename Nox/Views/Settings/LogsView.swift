import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive
import NoxParsing
import NoxDownload
import NoxState

struct LogsView: View {
    @ObservedObject var store = LogStore.shared
    @ObservedObject var localization = LocalizationManager.shared

    @State var showingClearConfirmation = false
    @State var shareFailureMessage: String?
    @State var showShareFailureAlert = false

    var body: some View {
        List {
            Section {
                Picker(L("日志保留"), selection: $store.retentionDays) {
                    ForEach(LogStore.retentionOptions, id: \.self) { value in
                        Text(retentionTitle(value)).tag(value)
                    }
                }
            } footer: {
                Text(L("超过保留天数的日志会被自动清理。"))
            }

            // 日志按块加载：进入时只有最近一块，更早的按需加载
            if store.canLoadMore {
                Section {
                    Button(L("加载更多")) {
                        store.loadMore()
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
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
                    ForEach(store.entries.reversed()) { entry in
                        logRow(entry)
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
