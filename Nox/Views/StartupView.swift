import SwiftUI
import UIKit

/// 启动准备页。
///
/// iOS 的静态 LaunchScreen 不能执行代码，所以这里用首帧覆盖层完成
/// 画中画基础设施预热。覆盖层保持完全不透明，只显示空白背景：
/// 不露出主界面、不显示图标 / 文字 / 加载提示。
struct StartupView: View {
    var body: some View {
        Color(.systemBackground)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}
