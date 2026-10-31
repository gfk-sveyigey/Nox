import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive
import NoxParsing
import NoxDownload
import NoxState

struct LicensesView: View {
    @ObservedObject var localization = LocalizationManager.shared

    var body: some View {
        Form {
            Section {
                creditRow(
                    name: "PiP",
                    author: "CaiWanFeng",
                    detail: L("原始画中画示例"),
                    urlString: "https://github.com/CaiWanFeng/PiP"
                )

                creditRow(
                    name: "GlobalRefresh-PiP",
                    author: "Yoroin",
                    detail: L("后台保活与画中画共存保护参考实现"),
                    urlString: "https://github.com/Yoroin/GlobalRefresh-PiP"
                )
            } header: {
                Text(L("来源与致谢"))
            } footer: {
                Text(L("本项目在其基础上实现后台保活与画中画共存保护，保留原作者的署名与项目地址；本项目与上述项目无隶属关系。"))
            }

            Section {
                Text(L("本项目仅供学习与个人测试使用。使用者在安装、签名和使用过程中需自行承担风险，请勿用于违反平台规则、商业侵权或其他不当用途。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L("免责声明"))
            }
        }
        .navigationTitle(L("开源许可与致谢"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 一条来源：名称、作者、用途说明与仓库链接（整行可点开仓库）。
    func creditRow(name: String, author: String, detail: String, urlString: String) -> some View {
        Link(destination: URL(string: urlString)!) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: name)
                    .foregroundStyle(.primary)

                Text(String(format: L("作者：%@"), author))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(verbatim: urlString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 「下载设置」二级页：同时下载任务数、下载清晰度，以及多线程（分片）相关的开关。
