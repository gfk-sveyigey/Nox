import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxParsing
import NoxDownload
import NoxState
import NoxBrowser

/// 文字统一用 `.primary`（深色）而不是 Button 默认的强调色，避免蓝字看不清。
struct ParseVariantRow: View {
    let variant: VideoVariant

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(variant.quality.isEmpty ? L("未知清晰度") : variant.quality)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(verbatim: variant.format.isEmpty ? "VIDEO" : variant.format.uppercased())

                    if let host = variant.url.host {
                        Text("·")
                        Text(host).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.tint)
        }
    }
}

// MARK: - 玻璃样式

