import SwiftUI
import UIKit
import NoxCore

/// 启动准备页。
///
/// iOS 的静态 LaunchScreen 不能执行代码，所以这里用首帧覆盖层完成
/// 画中画基础设施预热，再淡出进入主界面。准备失败或用户没选画中画时
/// 只显示一个很短的品牌过渡，不阻塞使用。
struct StartupView: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.22),
                    Color(.systemBackground)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                icon
                    .shadow(color: .black.opacity(0.12), radius: 18, y: 10)

                Text(SettingsView.appName)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                ProgressView()
                    .controlSize(.regular)
                    .tint(.accentColor)
                    .scaleEffect(1.1)

                Text(L("正在准备后台下载…"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .scaleEffect(appeared ? 1 : 0.94)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) {
                appeared = true
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let image = SettingsView.appIcon {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 108, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .fill(Color.accentColor.opacity(0.16))
                .frame(width: 108, height: 108)
                .overlay {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(Color.accentColor)
                }
        }
    }
}
