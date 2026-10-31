import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxParsing
import NoxDownload
import NoxState
import NoxBrowser

// MARK: - 悬浮入口

extension VideoBrowserView {
    // MARK: - 悬浮入口（解析 / 嗅探）

    /// 「通用嗅探」在设置页是否开启
    var isSnifferEnabled: Bool {
        appState.isSiteEnabled(SnifferSite.identifier)
    }

    /// 当前页面是否由通用嗅探兜底（而不是被某个具名站点解析器接管）。
    ///
    /// 判据只看**当前实际生效的解析器**：`GenericSnifferParser.canHandle` 对任何
    /// http(s) 地址都返回 true，所以「通用生效」= 没有具名站点能处理这个页面。
    var isUsingGenericSniffer: Bool {
        parser.currentParserIdentifier == SnifferSite.identifier
    }

    /// 只有当前页面**确实靠通用嗅探兜底**时才显示嗅探入口。
    ///
    /// 页面被具名站点解析器（如 Pornhub）命中时，「解析视频」已经能给出更准确的
    /// 清晰度清单，再摆一个嗅探入口只会得到重复且标注更差的结果。
    /// 反过来，把某个站点的开关关掉，该站点页面就会自动回落到嗅探 —— 语义自洽。
    var isSnifferBadgeVisible: Bool {
        isSnifferEnabled && isUsingGenericSniffer && !sniffer.items.isEmpty
    }

    /// 仅当具名站点解析器能处理当前页面时才显示「解析视频」。
    ///
    /// 关键点：通用嗅探对任何页面都「可解析」，若只看 `canParseCurrentPage`，
    /// 那么 Pornhub 首页这类「站内但不可解析」的页面上会同时冒出两个入口
    /// （解析视频其实也是走嗅探，纯属重复）。因此这里额外要求当前页面**不是**
    /// 通用嗅探兜底 —— 两个入口在定义上互斥，任何页面都只会出现其中一个。
    var isParseBadgeVisible: Bool {
        parser.canParseCurrentPage && !isUsingGenericSniffer
    }

    /// 「解析视频」悬浮胶囊：与嗅探入口同样的样式，点击弹出半屏面板。
    var parseBadge: some View {
        Button {
            parsedVideo = nil
            parseError = nil
            showParseSheet = true
            Task { await parse() }
        } label: {
            HStack(spacing: 6) {
                if isParsing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle")
                }

                Text(L("解析视频"))
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .browserGlassBar(cornerRadius: nil)
        .zIndex(1)
        .accessibilityLabel(L("解析视频"))
        .sheet(isPresented: $showParseSheet) {
            parseSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    /// 悬浮胶囊：显示当前已嗅探到的资源数。
    ///
    /// 用 `contentShape(Capsule())` 把命中区域收敛到胶囊本身，
    /// 否则外层留白会落到 WebView 上（表现为「点按钮顺带点了页面」）。
    /// `.sheet` 挂在徽标上而不是外层 `VStack`：后者已挂了 `parseSheet`，
    /// 同一视图叠两个 `.sheet` 会互相干扰。
    var snifferBadge: some View {
        Button {
            showSniffer = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")

                Text(String(sniffer.items.count))
                    .monospacedDigit()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .browserGlassBar(cornerRadius: nil)
        .zIndex(1)
        .accessibilityLabel(L("已嗅探"))
        .sheet(isPresented: $showSniffer) {
            SnifferSheet(
                onRescan: {
                    await parser.rescanPage()
                },
                onDownload: { item in
                    download(item)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}
