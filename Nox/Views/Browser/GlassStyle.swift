import SwiftUI
import NoxState

extension View {
    func browserGlassButton() -> some View {
        modifier(BrowserGlassButtonStyle())
    }
    func browserGlassBar(cornerRadius: CGFloat? = 12) -> some View {
        modifier(BrowserGlassBarStyle(cornerRadius: cornerRadius))
    }
}

private struct BrowserGlassButtonStyle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private struct BrowserGlassBarStyle: ViewModifier {
    let cornerRadius: CGFloat?
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if let cornerRadius {
                content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            } else {
                content.glassEffect(.regular, in: .capsule)
            }
        } else {
            if let cornerRadius {
                content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                content.background(.ultraThinMaterial, in: Capsule())
            }
        }
    }
}
