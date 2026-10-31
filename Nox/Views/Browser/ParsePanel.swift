import SwiftUI
import UIKit
import WebKit
import NoxCore
import NoxParsing
import NoxDownload
import NoxState
import NoxBrowser

// MARK: - 解析面板

extension VideoBrowserView {
    // MARK: - 解析面板（半屏）

    var parseSheet: some View {
        NavigationStack {
            Group {
                if isParsing {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(L("正在解析…"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let video = parsedVideo, !video.variants.isEmpty {
                    List(video.variants) { variant in
                        Button {
                            Task {
                                await download(variant)
                            }
                        } label: {
                            ParseVariantRow(variant: variant)
                        }
                        // 与嗅探面板一致的左滑复制链接
                        .swipeActions(edge: .trailing) {
                            Button {
                                UIPasteboard.general.string = variant.url.absoluteString
                            } label: {
                                Label(L("复制链接"), systemImage: "doc.on.doc")
                            }
                            .tint(.indigo)
                        }
                    }
                    .listStyle(.plain)
                } else {
                    ContentUnavailableView(
                        L("解析失败"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(parseError ?? L("没有找到可下载的视频清晰度。"))
                    )
                }
            }
            .navigationTitle(Text(parsedVideo?.title ?? L("解析视频")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("关闭")) {
                        showParseSheet = false
                    }
                }

                // 解析失败或结果过期时，不必退回页面重开面板，直接在这里重试。
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await reparse() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isParsing || !parser.canParseCurrentPage)
                    .accessibilityLabel(L("重新解析"))
                }
            }
        }
    }
}
