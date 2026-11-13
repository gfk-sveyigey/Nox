import SwiftUI
import NoxCore

struct AboutView: View {
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Image("AppIconPreview")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Text("Nox")
                        .font(.largeTitle.bold())
                    Text(L("浏览、发现，保存你喜欢的视频。"))
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 10) {
                    feature(title: L("浏览"), detail: L("使用内置浏览器访问网站并收藏常用网页。"),
                            icon: "safari", color: .blue)
                    feature(title: L("解析"), detail: L("通过解析插件或资源嗅探发现可下载内容。"),
                            icon: "dot.radiowaves.left.and.right", color: .purple)
                    feature(title: L("任务"), detail: L("管理下载任务，支持暂停、继续和后台下载。"),
                            icon: "arrow.down.circle", color: .green)
                }

                VStack(spacing: 10) {
                    Link(destination: URL(string: "https://github.com/gfk-sveyigey")!) {
                        infoCard(title: L("作者"), detail: "Aholic", trailingIcon: "arrow.up.right") {
                            Image("AuthorAvatar")
                                .resizable()
                                .scaledToFill()
                                .clipShape(Circle())
                        }
                    }
                    .accessibilityLabel("Aholic, GitHub")

                    Link(destination: URL(string: "https://github.com/gfk-sveyigey/Nox")!) {
                        infoCard(title: L("项目地址"), detail: "github.com/gfk-sveyigey/Nox", trailingIcon: "arrow.up.right") {
                            Image(systemName: "link.circle")
                                .font(.system(size: 32, weight: .regular))
                                .foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink {
                        LicensesView()
                    } label: {
                        infoCard(title: L("开源许可与致谢"), detail: L("查看第三方项目、许可信息与致谢。"), trailingIcon: "chevron.right") {
                            Image(systemName: "checkmark.seal")
                                .font(.system(size: 21, weight: .medium))
                                .foregroundStyle(.pink)
                                .frame(width: 40, height: 40)
                                .background(.pink.opacity(0.1), in: Circle())
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .buttonStyle(.plain)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationTitle(L("关于"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func feature(title: String, detail: String, icon: String, color: Color) -> some View {
        infoCard(title: title, detail: detail, trailingIcon: nil) {
            iconTile(icon, color: color)
        }
    }

    private func infoCard<Icon: View>(
        title: String,
        detail: String,
        trailingIcon: String?,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            icon()
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let trailingIcon {
                Image(systemName: trailingIcon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .foregroundStyle(.primary)
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
