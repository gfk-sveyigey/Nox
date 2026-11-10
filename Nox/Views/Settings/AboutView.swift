import SwiftUI
import NoxCore

struct AboutView: View {
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Text("Nox")
                        .font(.largeTitle.bold())
                    Text("v" + SettingsView.appVersion)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(L("浏览、发现，保存你喜欢的视频。"))
                        .font(.body)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }

            Section(L("主要功能")) {
                Label(L("使用内置浏览器访问网站并收藏常用网页。"), systemImage: "safari")
                Label(L("通过解析插件或资源嗅探发现可下载内容。"), systemImage: "dot.radiowaves.left.and.right")
                Label(L("管理下载任务，支持暂停、继续和后台下载。"), systemImage: "arrow.down.circle")
            }

            Section {
                LabeledContent(L("作者"), value: "Aholic")
                Link(destination: URL(string: "https://github.com/gfk-sveyigey/Nox")!) {
                    Label(L("项目地址"), systemImage: "link")
                }
                NavigationLink {
                    LicensesView()
                } label: {
                    Text(L("开源许可与致谢"))
                }
            }
        }
        .navigationTitle(L("关于"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
