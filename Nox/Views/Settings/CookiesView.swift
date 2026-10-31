import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive
import NoxParsing
import NoxDownload
import NoxState

struct CookiesView: View {
    @ObservedObject var localization = LocalizationManager.shared

    @State var groups: [CookieManager.Group] = []
    @State var isLoading = true
    @State var showingClearConfirmation = false

    var totalCount: Int { groups.reduce(0) { $0 + $1.count } }

    var body: some View {
        List {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if groups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "shield")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(L("暂无 Cookie"))
                        .foregroundStyle(.secondary)
                    Text(L("浏览网页并登录后，这里会显示保存的登录状态。"))
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                Section {
                    LabeledContent(L("共计"), value: String(format: L("%d 个"), totalCount))
                }

                Section {
                    ForEach(groups) { group in
                        HStack {
                            Text(group.domain)
                            Spacer()
                            Text(String(format: L("%d 个"), group.count))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task {
                                    await CookieManager.delete(domain: group.domain)
                                    groups = await CookieManager.groups()
                                }
                            } label: {
                                Label(L("删除"), systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    Text(L("Cookie 用于保存网站登录状态。删除后，相关网站需要重新登录。"))
                }
            }
        }
        .navigationTitle(L("Cookie 管理"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { groups = await CookieManager.groups() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(L("刷新"))
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(groups.isEmpty)
                .accessibilityLabel(L("清空 Cookie"))
            }
        }
        .task {
            groups = await CookieManager.groups()
            isLoading = false
        }
        .alert(L("清空 Cookie？"), isPresented: $showingClearConfirmation) {
            Button(L("取消"), role: .cancel) {}
            Button(L("清空"), role: .destructive) {
                Task {
                    await CookieManager.clearAll()
                    groups = await CookieManager.groups()
                }
            }
        } message: {
            Text(L("所有网站保存的 Cookie 将被删除，相关网站需要重新登录。"))
        }
    }
}
