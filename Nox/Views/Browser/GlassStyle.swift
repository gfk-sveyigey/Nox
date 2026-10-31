import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxParsing
import NoxDownload
import NoxState
import NoxBrowser

extension View {
    @ViewBuilder
    func browserGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// 液态玻璃「容器」样式（地址栏、解析按钮）。
    ///
    /// - Parameter cornerRadius: 传具体值得圆角矩形（默认 12）；传 `nil` 得**胶囊形**，两端为半圆。
    @ViewBuilder
    func browserGlassBar(cornerRadius: CGFloat? = 12) -> some View {
        if #available(iOS 26.0, *) {
            if let cornerRadius {
                self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular, in: .capsule)
            }
        } else {
            if let cornerRadius {
                self.background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            } else {
                self.background(.ultraThinMaterial, in: Capsule())
            }
        }
    }
}

