import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxParsing
import NoxDownload
import NoxState
import NoxBrowser

// MARK: - 顶部地址栏

extension VideoBrowserView {
    // MARK: - 顶部地址栏

    /// 地址栏：中间是胶囊形输入框，主页与书签按钮各自独立浮在两侧。
    /// 页面向下滚动时高度收缩，回到顶部再展开；下沿叠一条加载进度条。
    var addressToolbar: some View {
        addressBar
            .padding(.horizontal, 10)
            .padding(.vertical, isScrolledDown ? 3 : 8)
            // 用 overlay 而不是 VStack：进度条不参与布局，出现 / 消失都不会让地址栏跳动。
            .overlay(alignment: .bottom) { loadProgressBar }
            .animation(.easeInOut(duration: 0.2), value: isScrolledDown)
    }

    var addressBar: some View {
        HStack(spacing: 8) {
            // 主页与书签各自是**独立**的悬浮按钮，不再塞进地址胶囊里。
            barButton(
                systemImage: "house",
                label: L("返回首页"),
                tint: .secondary,
                action: goHome
            )

            HStack(spacing: 6) {
                TextField(L("输入网页地址"), text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit {
                        openAddress()
                    }

                // 加载中且不在编辑地址时，把右侧的「清空」换成转圈 ——
                // 地址栏本身就是「正在加载」的提示（与 Safari 一致）。
                if showsLoadingIndicator, !addressFocused {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(L("正在加载…"))
                } else if !address.isEmpty {
                    Button {
                        address = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("清空地址栏"))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: barControlHeight)
            .browserGlassBar(cornerRadius: nil)

            barButton(
                systemImage: isCurrentPageBookmarked ? "bookmark.fill" : "bookmark",
                label: isCurrentPageBookmarked ? L("移除书签") : L("加入书签"),
                tint: isCurrentPageBookmarked ? Color.accentColor : Color.secondary,
                disabled: !canBookmarkCurrentPage,
                action: toggleBookmark
            )
        }
    }

    /// 是否在地址栏上显示加载提示。
    ///
    /// 两种来源：真实导航（`isLoading`，带 `estimatedProgress`）与同文档换页
    /// （`isSameDocumentLoading`，SPA 只改 path，没有任何导航回调、也没有进度）。
    /// 首页上没有「当前网页」的概念，加载中的 WebView 也盖在首页下面，所以不提示。
    var showsLoadingIndicator: Bool {
        (parser.isLoading || parser.isSameDocumentLoading) && !showingHome
    }

    /// 地址栏下沿的加载条。
    ///
    /// 为什么要有它：在页面里点链接时，`isUserInitiatedLoad` 为 false（旧页面会一直留到
    /// 新页面提交），页面区域看不出任何变化；SPA 只改 path 时连 `isLoading` 都不会变。
    /// 这条进度条就是那种时刻主要的「在加载」反馈。
    ///
    /// 两种形态：真实导航有 `estimatedProgress`，条子跟着进度长；同文档换页拿不到任何进度，
    /// 就固定显示一段（约 1/3 宽），靠呼吸动画表达「还在动」。
    var loadProgressBar: some View {
        GeometryReader { proxy in
            // 呼吸用 `TimelineView` 按时钟算亮度，而不是 `repeatForever` 的状态动画：
            // 状态动画会被同一批事务里的淡入 / 淡出（`withAnimation`）顶掉，
            // 表现就是「只看得到进度条在长，看不到呼吸」。这里亮度只由时间决定，
            // 不会被别的动画覆盖；不呼吸时 `paused` 掉，不额外耗电。
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isProgressPulsing || !isProgressVisible)) { context in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * progressBarWidthFactor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(pulseOpacity(at: context.date))
            }
        }
        .frame(height: 2.5)
        .opacity(isProgressVisible && !showingHome ? 1 : 0)
        .padding(.horizontal, 12)
        .allowsHitTesting(false)
    }

    /// 进度条当前占多宽。同文档换页拿不到任何进度，固定显示约 1/3 宽。
    var progressBarWidthFactor: Double {
        isProgressIndeterminate ? 0.33 : progressFraction
    }

    /// 呼吸灯的亮度：不呼吸时恒定 1；呼吸时在一个周期内于 0.35…1 之间来回。
    func pulseOpacity(at date: Date) -> Double {
        guard isProgressPulsing else { return 1 }
        let period: Double = 0.9
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        let breathe = 0.5 - 0.5 * cos(2 * Double.pi * phase)
        return 0.35 + 0.65 * breathe
    }

    /// 切换地址栏加载提示的显示状态。
    ///
    /// 开始加载：先把进度复位到可见下限（此刻条子是隐藏的，看不到回跳），再淡入并起呼吸。
    /// `estimatedProgress` 起步是 0，不复位的话进度条会「先看不见、再突然窜出来」。
    /// 加载结束：补满一格、稍作停顿再淡出，让「加载完成」这个动作本身能被看到。
    func updateProgressAppearance(isLoading: Bool) {
        if isLoading {
            // 同文档换页（SPA）拿不到任何进度，用「固定一段 + 呼吸」表达在动；
            // 真实导航有 `estimatedProgress`，条子跟着它长。
            isProgressIndeterminate = !parser.isLoading
            progressFraction = 0.08
            isProgressPulsing = true
            withAnimation(.easeOut(duration: 0.2)) {
                isProgressVisible = true
            }
        } else {
            isProgressPulsing = false
            withAnimation(.easeOut(duration: 0.2)) {
                progressFraction = 1
            }
            withAnimation(.easeIn(duration: 0.3).delay(0.25)) {
                isProgressVisible = false
            }
        }
    }
    

    /// 地址栏展开 / 收起时，三个控件共用的高度。
    var barControlHeight: CGFloat {
        isScrolledDown ? collapsedControlHeight : controlHeight
    }

    /// 地址栏两侧独立的圆形按钮（主页 / 书签）。
    func barButton(
        systemImage: String,
        label: String,
        tint: Color,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: barControlHeight, height: barControlHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .browserGlassBar(cornerRadius: nil)
        .accessibilityLabel(label)
    }

    /// 加载中 / 加载失败的页面内提示。
    ///
    /// 用不透明占位盖住 WebView：WKWebView 导航失败时会保留上一个页面，
    /// 只有盖住它，用户才能一眼看出「这个新地址没打开」，而不是弹窗叠在旧页面上。
    @ViewBuilder
    var webStateOverlay: some View {
        if let message = parser.loadErrorMessage {
            ContentUnavailableView {
                Label(L("无法打开该网页"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(L("重试")) { parser.retryLastLoad() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        } else if parser.isUserInitiatedLoad {
            VStack(spacing: 12) {
                ProgressView()
                Text(L("正在加载…"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        }
    }

    func updateCollapsedState(for offset: CGFloat) {
        let collapsed = offset > 24
        guard collapsed != isScrolledDown else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            isScrolledDown = collapsed
        }
    }
}
