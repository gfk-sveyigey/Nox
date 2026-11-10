import SwiftUI
import NoxCore

struct AboutView: View {
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image("AppIconPreview")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.bottom, 4)
                    Text("Nox")
                        .font(.largeTitle.bold())
                    Text(L("浏览、发现，保存你喜欢的视频。"))
                        .font(.body)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }

            Section {
                feature(title: L("浏览"), detail: L("使用内置浏览器访问网站并收藏常用网页。"),
                        icon: "safari", color: .blue)
                feature(title: L("解析"), detail: L("通过解析插件或资源嗅探发现可下载内容。"),
                        icon: "dot.radiowaves.left.and.right", color: .purple)
                feature(title: L("任务"), detail: L("管理下载任务，支持暂停、继续和后台下载。"),
                        icon: "arrow.down.circle", color: .green)
            }

            Section {
                HStack {
                    infoLabel(L("作者"), icon: "person.crop.circle", color: .orange)
                    Spacer()
                    Text("Aholic").foregroundStyle(.secondary)
                }
                Link(destination: URL(string: "https://github.com/gfk-sveyigey/Nox")!) {
                    HStack {
                        infoLabel(L("项目地址"), icon: "link", color: .blue)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                NavigationLink {
                    LicensesView()
                } label: {
                    infoLabel(L("开源许可与致谢"), icon: "heart.text.square", color: .pink)
                }
            }

        }
        .navigationTitle(L("关于"))
        .navigationBarTitleDisplayMode(.inline)
    }
    private func feature(title: String, detail: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 14) {
            iconTile(icon, color: color)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
    }

    private func infoLabel(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            iconTile(icon, color: color)
            Text(title).foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
    }

    private func iconTile(_ icon: String, color: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 40, height: 40)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
            .accessibilityHidden(true)
    }

}
