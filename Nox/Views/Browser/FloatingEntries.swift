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

    var canOpenParsePanel: Bool {
        !showingHome && !isParsing && (isParseBadgeVisible || isSnifferBadgeVisible)
    }

    func openParsePanel() {
        guard canOpenParsePanel else { return }
        if isSnifferBadgeVisible {
            showSniffer = true
        } else {
            parsedVideo = nil
            parseError = nil
            showParseSheet = true
            Task { await parse() }
        }
    }

    var browserParseButton: some View {
        NativeParseButton(title: L("解析视频"), isParsing: isParsing, isEnabled: canOpenParsePanel) {
            openParsePanel()
        }
        .fixedSize()
    }

}

/// Home does not participate in the system's scroll-driven tab minimization.
struct BrowserMinimizationPreference: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// UIKit owns the glass rendering, interaction and accessibility.
struct NativeParseButton: UIViewRepresentable {
    let title: String
    var systemImage: String = "arrow.down.circle"
    let isParsing: Bool
    var isEnabled: Bool = true
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.addTarget(context.coordinator, action: #selector(Coordinator.activate), for: .touchUpInside)
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = .glass()
        } else {
            configuration = .tinted()
        }
        configuration.cornerStyle = .capsule
        configuration.title = nil
        configuration.image = UIImage(systemName: systemImage)
        configuration.imagePadding = 0
        configuration.showsActivityIndicator = isParsing
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        button.configuration = configuration
        button.isEnabled = isEnabled
        button.accessibilityLabel = title
        button.invalidateIntrinsicContentSize()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        return CGSize(width: 48, height: 48)
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func activate() { action() }
    }
}

struct BrowserParseAvailability: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
