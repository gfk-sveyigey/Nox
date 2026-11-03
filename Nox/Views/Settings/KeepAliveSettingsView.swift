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
                Picker(L("后台方式"), selection: Binding(
                    get: { appState.keepAliveMode },
                    set: { manager.setKeepAliveMode($0) }
                )) {
                    ForEach(KeepAliveMode.allCases.filter(\.isAvailable)) { mode in
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

                    // 上游是首页的一键开关；这里放在设置里，随时可以拉起或关闭悬浮窗。
                    Toggle(isOn: Binding(
                        get: { manager.isPiPWindowRunning },
                        set: { manager.setPiPWindowEnabled($0) }
                    )) {
                        Text(L("启动悬浮窗"))
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.keepAliveMode.detail)
                    if appState.keepAliveMode == .pictureInPicture {
                        Text(L("拖动到最左即最小：窗口高 0.1pt，视觉隐藏、不影响操作；越往右窗口越大。"))
                        Text(L("也可以随时手动启动或关闭悬浮窗，不受下载任务影响；关闭后下载仍按当前后台方式继续。"))
                    }
                }
            }

            // 系统下载和仅前台下载都没有额外保活，持续处理则由系统
            // 按当前下载任务授予执行时间，这三档都不需要选生命周期。
            if appState.keepAliveMode.startsKeepAlive,
               appState.keepAliveMode != .continuedProcessing {
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
                    Text(L("跟随下载任务：有下载任务时才保活。启动即常驻：进入前台即拉起并一直保持，直到切换到「系统下载」或「仅前台下载」。"))
                }
            }

            if appState.keepAliveMode.startsKeepAlive,
               appState.keepAliveMode != .silentAudio {
                Section {
                    Toggle(isOn: Binding(
                        get: { appState.keepAliveSilentAudioFallback },
                        set: { manager.setKeepAliveSilentAudioFallback($0) }
                    )) {
                        Text(L("中断后改用静音音频"))
                    }
                } footer: {
                    Text(L("开启后，画中画或持续处理被系统中断时会自动改用静音音频继续下载。这会占用音频会话，可能打断其他 App 正在播放的声音。"))
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
        .navigationTitle(L("后台下载"))
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
