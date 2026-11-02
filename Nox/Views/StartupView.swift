import SwiftUI
import UIKit

/// 启动准备页。
///
/// iOS 的静态 LaunchScreen 不能执行代码，所以这里用首帧覆盖层完成
/// 画中画基础设施预热。覆盖层不露出主界面，只保留与应用图标一致的
/// 深色背景、居中图标和应用名称。
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

            VStack(spacing: 18) {
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

                Text(verbatim: Self.appName)
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .tracking(0.5)
            }
            .scaleEffect(appeared ? 1 : 0.94)
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

    private static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Nox"
    }
}
