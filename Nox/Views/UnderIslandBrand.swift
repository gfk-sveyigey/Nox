import SwiftUI
import UIKit

/// 藏在灵动岛硬件下方的小品牌标记。
///
/// 正常使用时这块区域被灵动岛完全盖住；系统截图不绘制挖孔，上划进入多任务
/// 导致画面缩放时也会露出来。因此它只做装饰：不参与布局、不接收点击，
/// 也不影响现有页面的安全区。
///
/// 只在灵动岛机型显示。灵动岛机型的顶部安全区约 59–62pt，
/// 刘海机最大约 50pt，用 55pt 作为分界即可只命中灵动岛机型。
struct UnderIslandBrand: View {
    @State private var topInset: CGFloat = 0

    private static let markHeight: CGFloat = 24
    private static let dynamicIslandMinimumInset: CGFloat = 55

    var body: some View {
        Group {
            if topInset >= Self.dynamicIslandMinimumInset {
                content
                    .padding(.top, (topInset - Self.markHeight) / 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            refreshTopInset()
            // 首次 onAppear 时窗口可能刚挂上，补一次读取安全区。
            DispatchQueue.main.async(execute: refreshTopInset)
        }
    }

    private var content: some View {
        HStack(spacing: 6) {
            Image("AppIconPreview")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: Self.markHeight, height: Self.markHeight)
                .clipShape(RoundedRectangle(cornerRadius: Self.markHeight * 0.23, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.markHeight * 0.23, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                }

            Text(verbatim: "NOX")
                .font(.custom("AvenirNext-DemiBold", size: 11))
                .tracking(1.2)
                .foregroundStyle(Color.primary.opacity(0.86))
        }
    }

    private func refreshTopInset() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
        topInset = window?.safeAreaInsets.top ?? 0
    }
}
