import SwiftUI
import UIKit

/// 启动准备页。
///
/// iOS 的静态 LaunchScreen 不能执行代码，所以这里用首帧覆盖层完成
/// 画中画基础设施预热。覆盖层不露出主界面、不显示文字或加载提示，
/// 只保留与应用图标一致的深色背景和居中的图标。
struct StartupView: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color("LaunchBackground")

            RadialGradient(
                colors: [
                    Color.white.opacity(0.11),
                    Color.white.opacity(0.025),
                    .clear
                ],
                center: .center,
                startRadius: 8,
                endRadius: 300
            )

            Image("AppIconPreview")
                .resizable()
                .scaledToFit()
                .frame(width: 136, height: 136)
                .clipShape(RoundedRectangle(cornerRadius: 31, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 31, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                }
                .shadow(color: Color.white.opacity(0.14), radius: 34)
                .scaleEffect(appeared ? 1 : 0.92)
                .opacity(appeared ? 1 : 0)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) {
                appeared = true
            }
        }
    }
}
