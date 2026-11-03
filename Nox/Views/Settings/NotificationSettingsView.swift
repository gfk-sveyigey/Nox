import SwiftUI
import NoxDownload
import NoxState

/// 「推送通知」二级页：选择哪些事件发通知，以及实时活动 / 通知显示多少任务信息。
struct NotificationSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var manager: DownloadManager

    init(manager: DownloadManager) {
        _manager = ObservedObject(wrappedValue: manager)
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { appState.keepAliveNotifications },
                    set: { manager.setKeepAliveNotifications($0) }
                )) {
                    Text(L("保活中断时通知"))
                }

                Toggle(isOn: Binding(
                    get: { appState.downloadCompletionNotifications },
                    set: { manager.setDownloadCompletionNotifications($0) }
                )) {
                    Text(L("下载完成后通知"))
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("保活中断提醒仅在持续处理、静音音频或画中画被系统中断时生效。"))
                    Text(L("首次开启通知时需要允许 Nox 发送通知。"))
                }
            }

            Section {
                Picker(selection: Binding(
                    get: { appState.showsTaskNames },
                    set: { manager.setShowsTaskNames($0) }
                )) {
                    Text(L("显示具体任务名")).tag(true)
                    Text(L("仅提示有任务完成")).tag(false)
                } label: {
                    Text(L("显示内容"))
                }
                .pickerStyle(.inline)
            } footer: {
                Text(L("实时活动与通知共用这套设置。关闭任务名后，实时活动显示「正在下载」，完成通知显示「有一个任务完成」。"))
            }
        }
        .navigationTitle(L("推送通知"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
