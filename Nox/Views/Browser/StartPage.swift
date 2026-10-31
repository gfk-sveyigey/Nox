import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxParsing
import NoxDownload
import NoxState
import NoxBrowser

// MARK: - 首页与书签

extension VideoBrowserView {
    // MARK: - 首页与书签

    /// 首页：还没打开任何页面、或点地址栏左侧主页按钮时显示。
    ///
    /// 用原生 SwiftUI 而不是加载一个空白网页：深色模式下背景才会跟随系统，
    /// 不会出现「整个浏览区域还是白底」的问题。
    var homeScreen: some View {
        ZStack {
            Color(.systemBackground)

            if appState.bookmarks.isEmpty {
                ContentUnavailableView(
                    L("还没有书签"),
                    systemImage: "book",
                    description: Text(L("打开网页后，点地址栏右侧的书签按钮即可收藏。"))
                )
            } else {
                List {
                    Section {
                        ForEach(appState.bookmarks) { bookmark in
                            Button {
                                openBookmark(bookmark)
                            } label: {
                                bookmarkRow(bookmark)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    appState.removeBookmark(bookmark)
                                } label: {
                                    Label(L("删除"), systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text(L("书签"))
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func bookmarkRow(_ bookmark: Bookmark) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(bookmark.displayTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(bookmark.url.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    var currentPageURL: URL? { parser.currentPageURL }

    /// 有页面、且不在首页时，才允许收藏。
    var canBookmarkCurrentPage: Bool {
        !showingHome && currentPageURL != nil
    }

    var isCurrentPageBookmarked: Bool {
        guard let url = currentPageURL else { return false }
        return appState.isBookmarked(url)
    }

    func toggleBookmark() {
        guard let url = currentPageURL else { return }

        let title = parser.currentPageTitle ?? url.host ?? url.absoluteString
        withAnimation { appState.toggleBookmark(title: title, url: url) }
    }

    func openBookmark(_ bookmark: Bookmark) {
        addressFocused = false
        address = bookmark.url.absoluteString
        showingHome = false
        parser.load(bookmark.url)
    }

    /// 回到首页。不卸载当前页面，从书签 / 地址栏再前进即可。
    func goHome() {
        addressFocused = false
        // 回到首页时地址栏也要清空：否则会残留上一个网址，
        // 看起来像「首页其实还停在这个地址」。
        address = ""
        parser.clearLoadError()
        withAnimation(.easeInOut(duration: 0.2)) { showingHome = true }
    }
}
