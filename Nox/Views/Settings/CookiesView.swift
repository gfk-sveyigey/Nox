import SwiftUI
import UIKit
import WebKit
import NoxCore

/// 「Cookie 管理」二级页：按站点归组，点进去查看该站点的全部 Cookie。
///
/// 与下载页一致，双指滑动进入多选，按站点批量删除。
struct CookiesView: View {
    @ObservedObject var localization = LocalizationManager.shared

    @State var groups: [CookieManager.Group] = []
    @State var isLoading = true
    @State var showingClearConfirmation = false
    @State var showingDeleteConfirmation = false
    @State var editMode: EditMode = .inactive
    @State var selection = Set<String>()
    @State var rowFrames: [String: CGRect] = [:]
    @State var isVisible = false
    /// NavigationStack push 到站点详情时父页不会触发 onDisappear；
    /// 用这个状态确保详情页的双指滑动不会把父页带入多选。
    @State var isShowingDomain = false

    var body: some View {
        List(selection: listSelection) {
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
                    ForEach(groups) { group in
                        row(for: group)
                    }
                } footer: {
                    Text(L("Cookie 用于保存网站登录状态。删除后，相关网站需要重新登录。"))
                }
            }
        }
        .environment(\.editMode, $editMode)
        .onPreferenceChange(CookieRowFrameKey.self) { rowFrames = $0 }
        .navigationTitle(L("Cookie 管理"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(editMode.isEditing)
        .toolbar { toolbarContent }
        .onChange(of: editMode) { _, newValue in
            if !newValue.isEditing { selection.removeAll() }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task { await reload() }
        .twoFingerPanToSelect(
            isEnabled: isVisible && !isShowingDomain,
            onBegin: { beginTwoFingerSelection() },
            onPath: { selectRows(in: $0) }
        )
        .alert(L("清空 Cookie？"), isPresented: $showingClearConfirmation) {
            Button(L("取消"), role: .cancel) {}
            Button(L("清空"), role: .destructive) {
                Task {
                    await CookieManager.clearAll()
                    await reload()
                }
            }
        } message: {
            Text(L("所有网站保存的 Cookie 将被删除，相关网站需要重新登录。"))
        }
        .alert(L("删除所选 Cookie？"), isPresented: $showingDeleteConfirmation) {
            Button(L("取消"), role: .cancel) {}
            Button(L("删除"), role: .destructive) {
                deleteSelected()
            }
        } message: {
            Text(String(format: L("将删除 %d 个站点保存的 Cookie。"), selection.count))
        }
    }

    @ViewBuilder
    func row(for group: CookieManager.Group) -> some View {
        Group {
            if editMode.isEditing {
                groupLabel(group)
                    .tag(group.domain)
            } else {
                NavigationLink {
                    CookieDomainView(domain: group.domain)
                        .onAppear { isShowingDomain = true }
                        .onDisappear { isShowingDomain = false }
                } label: {
                    groupLabel(group)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task {
                            await CookieManager.delete(domain: group.domain)
                            await reload()
                        }
                    } label: {
                        Label(L("删除"), systemImage: "trash")
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CookieRowFrameKey.self,
                    value: [group.domain: proxy.frame(in: .global)]
                )
            }
        }
    }

    func groupLabel(_ group: CookieManager.Group) -> some View {
        HStack {
            Text(group.domain)
            Spacer()
            Text(String(format: L("%d 个"), group.count))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    var listSelection: Binding<Set<String>> {
        Binding(
            get: { editMode.isEditing ? selection : [] },
            set: { newValue in
                guard editMode.isEditing else { return }
                selection = newValue
            }
        )
    }

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if editMode.isEditing {
                Button(L("完成")) {
                    withAnimation { editMode = .inactive }
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            if editMode.isEditing {
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Text(L("删除"))
                        .foregroundStyle(.red)
                }
                .disabled(selection.isEmpty)
            } else {
                Menu {
                    Button {
                        Task { await reload() }
                    } label: {
                        Label(L("刷新"), systemImage: "arrow.clockwise")
                    }

                    Divider()

                    Button(role: .destructive) {
                        showingClearConfirmation = true
                    } label: {
                        Label(L("清空 Cookie"), systemImage: "trash")
                    }
                    .disabled(groups.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(L("更多"))
            }
        }
    }

    @MainActor
    func reload() async {
        groups = await CookieManager.groups()
        isLoading = false
    }

    func beginTwoFingerSelection() {
        guard !editMode.isEditing else { return }
        withAnimation { editMode = .active }
    }

    func selectRows(in path: CGRect) {
        let domains = rowFrames.compactMap { domain, frame in
            frame.intersects(path) ? domain : nil
        }
        guard !domains.isEmpty else { return }
        selection.formUnion(domains)
    }

    func deleteSelected() {
        let domains = selection
        selection.removeAll()
        withAnimation { editMode = .inactive }
        Task {
            await CookieManager.delete(domains: domains)
            await reload()
        }
    }
}

/// 单个站点的 Cookie 详情：显示名称、值、路径、有效期与安全标记。
struct CookieDomainView: View {
    let domain: String

    @ObservedObject var localization = LocalizationManager.shared
    @State var cookies: [HTTPCookie] = []
    @State var isLoading = true
    @State var showingClearConfirmation = false

    var body: some View {
        List {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if cookies.isEmpty {
                ContentUnavailableView(
                    L("暂无 Cookie"),
                    systemImage: "shield",
                    description: Text(L("浏览网页并登录后，这里会显示保存的登录状态。"))
                )
            } else {
                Section {
                    ForEach(Array(cookies.enumerated()), id: \.offset) { _, cookie in
                        CookieRow(cookie: cookie)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task {
                                        await CookieManager.delete(cookie: cookie)
                                        await reload()
                                    }
                                } label: {
                                    Label(L("删除"), systemImage: "trash")
                                }
                            }
                    }
                } footer: {
                    Text(L("删除后，该网站需要重新登录。"))
                }
            }
        }
        .navigationTitle(domain)
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await reload() }
                    } label: {
                        Label(L("刷新"), systemImage: "arrow.clockwise")
                    }

                    Divider()

                    Button(role: .destructive) {
                        showingClearConfirmation = true
                    } label: {
                        Label(L("删除该站点的 Cookie"), systemImage: "trash")
                    }
                    .disabled(cookies.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(L("更多"))
            }
        }
        .alert(L("删除该站点的 Cookie？"), isPresented: $showingClearConfirmation) {
            Button(L("取消"), role: .cancel) {}
            Button(L("删除"), role: .destructive) {
                Task {
                    await CookieManager.delete(domain: domain)
                    await reload()
                }
            }
        } message: {
            Text(L("该网站需要重新登录。"))
        }
    }

    @MainActor
    func reload() async {
        cookies = await CookieManager.cookies(for: domain)
        isLoading = false
    }
}

private struct CookieRow: View {
    let cookie: HTTPCookie

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(cookie.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if cookie.isSecure {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .accessibilityLabel(L("安全 Cookie"))
                }
                if cookie.isHTTPOnly {
                    Text("HTTPOnly")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Text(cookie.value)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)

            HStack(spacing: 10) {
                Text(cookie.domain)
                    .lineLimit(1)

                Text(cookie.path)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let expires = cookie.expiresDate {
                    Text(expires, format: .dateTime.year().month().day())
                } else {
                    Text(L("会话 Cookie"))
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

private struct CookieRowFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
