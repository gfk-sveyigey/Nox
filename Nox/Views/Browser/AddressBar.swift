import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxParsing
import NoxDownload
import NoxState
import NoxBrowser

// MARK: - 顶部地址栏

extension VideoBrowserView {
    // MARK: - 顶部地址栏

    @ToolbarContentBuilder
    var browserNavigationItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: goHome) { Image(systemName: "house") }
                .accessibilityLabel(L("返回首页"))
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 6) {
                TextField(L("输入网页地址"), text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit { openAddress() }
                    .textFieldStyle(.roundedBorder)
                if showsLoadingIndicator {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(L("正在加载…"))
                }
            }
            .frame(maxWidth: .infinity)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: toggleBookmark) {
                Image(systemName: isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
            }
            .disabled(!canBookmarkCurrentPage)
            .accessibilityLabel(isCurrentPageBookmarked ? L("移除书签") : L("加入书签"))
        }
    }

    var showsLoadingIndicator: Bool {
        (parser.isLoading || parser.isSameDocumentLoading) && !showingHome
    }

    /// 加载中 / 加载失败的页面内提示。
    ///
    /// 用不透明占位盖住 WebView：WKWebView 导航失败时会保留上一个页面，
    /// 只有盖住它，用户才能一眼看出「这个新地址没打开」，而不是弹窗叠在旧页面上。
    @ViewBuilder
    var webStateOverlay: some View {
        if let message = parser.loadErrorMessage {
            ContentUnavailableView {
                Label(L("无法打开该网页"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(L("重试")) { parser.retryLastLoad() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        } else if parser.isUserInitiatedLoad {
            VStack(spacing: 12) {
                ProgressView()
                Text(L("正在加载…"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        }
    }

}
