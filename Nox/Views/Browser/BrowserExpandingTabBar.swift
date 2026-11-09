import SwiftUI
import NoxCore

/// One persistent capsule animates its width into a circle anchored at the left.
struct BrowserExpandingTabBar: View {
    let expanded: Bool
    let onExpand: () -> Void
    let onSelect: (Int) -> Void

    var body: some View {
        GeometryReader { geometry in
            let height: CGFloat = 56
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    tab(0, title: L("浏览"), icon: "safari")
                    tab(1, title: L("下载"), icon: "arrow.down.circle")
                    tab(2, title: L("设置"), icon: "gearshape")
                }
                .frame(width: expanded ? geometry.size.width : height, height: height)
                .opacity(expanded ? 1 : 0)
                .allowsHitTesting(expanded)
                .accessibilityHidden(!expanded)
                Button(action: onExpand) {
                    Image(systemName: "safari")
                        .font(.system(size: 23))
                        .frame(width: height, height: height)
                }
                .opacity(expanded ? 0 : 1)
                .allowsHitTesting(!expanded)
                .accessibilityHidden(expanded)
                .accessibilityLabel(L("切换标签页"))
            }
            .frame(width: expanded ? geometry.size.width : height, height: height, alignment: .leading)
            .clipShape(Capsule())
            .browserGlassBar(cornerRadius: nil)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: expanded)
        }
        .frame(height: 56)
    }

    private func tab(_ index: Int, title: String, icon: String) -> some View {
        Button { onSelect(index) } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 21))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
        }
    }
}
