import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive
import NoxParsing
import NoxDownload
import NoxState

struct KeepAliveSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var localization = LocalizationManager.shared
    @ObservedObject var manager: DownloadManager

    init(manager: DownloadManager) {
        _manager = ObservedObject(wrappedValue: manager)
    }

    var body: some View {
        Form {
            Section {
                Picker(L("保活方式"), selection: Binding(
                    get: { appState.keepAliveMode },
                    set: { manager.setKeepAliveMode($0) }
                )) {
                    ForEach(KeepAliveMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                // 只有画中画才有悬浮窗，其它保活方式下这个滑块没有意义。
                if appState.keepAliveMode == .pictureInPicture {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(L("画中画窗口大小"))
                            Spacer()
                            Text(pipWindowSizeTitle)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Slider(
                            value: Binding(
                                get: { appState.pipWindowHeight },
                                set: { manager.setPiPWindowHeight($0) }
                            ),
                            in: AppState.pipWindowHeightRange,
                            step: 1
                        )
                    }
                }
            } footer: {
                if appState.keepAliveMode == .pictureInPicture {
                    Text(L("拖动到最左即最小：窗口高 0.1pt，视觉隐藏、不影响操作；越往右窗口越大。"))
                }
            }

            // 保活方式为「关闭」时不需要选生命周期。
            if appState.keepAliveMode != .off {
                Section {
                    Picker(L("保活模式"), selection: Binding(
                        get: { appState.keepAliveLifetime },
                        set: { manager.setKeepAliveLifetime($0) }
                    )) {
                        ForEach(KeepAliveLifetime.allCases) { lifetime in
                            Text(lifetime.title).tag(lifetime)
                        }
                    }
                } footer: {
                    Text(L("跟随下载任务：有下载任务时才保活。启动即常驻：进入前台即拉起并一直保持，直到把保活方式设为「关闭」。"))
                }
            }

            // 只有画中画需要共存保护；选了其它保活方式时这一组整段隐藏。
            if appState.keepAliveMode == .pictureInPicture {
                Section {
                    Picker(L("共存保护不可用时"), selection: Binding(
                        get: { appState.pipCoexistenceFallback },
                        set: { manager.setPiPCoexistenceFallback($0) }
                    )) {
                        ForEach(PiPCoexistenceFallback.allCases) { fallback in
                            Text(fallback.title).tag(fallback)
                        }
                    }
                } footer: {
                    Text(L("画中画可能与其他 App 的画中画互相打断。这里选择共存保护不可用时如何处理。"))
                }
            }

            // 详细日志只影响画中画保活的诊断输出，不改变保活行为。
            if appState.keepAliveMode == .pictureInPicture {
                Section {
                    Toggle(isOn: Binding(
                        get: { appState.pipVerboseLogging },
                        set: { manager.setPiPVerboseLogging($0) }
                    )) {
                        Text(L("详细日志"))
                    }
                } footer: {
                    Text(L("开启后记录画中画启动、就绪判断、重试及系统回调等诊断信息，日志量会明显增加；排查完成后建议关闭。"))
                }
            }
        }
        .navigationTitle(L("后台保活"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 滑块当前值说明：最左为「最小」（隐藏），其余显示高度点数。
    var pipWindowSizeTitle: String {
        appState.pipWindowHeight < 1 ? L("最小") : "\(Int(appState.pipWindowHeight.rounded())) pt"
    }
}

/// 「解析来源」开关的二级页（各视频站点 + Sniffer）。
///
/// 站点数量增长后，这里会自动变长，不用改设置主页的结构。
