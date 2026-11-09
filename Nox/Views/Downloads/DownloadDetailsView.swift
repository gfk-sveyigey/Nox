import SwiftUI
import NoxCore
import NoxDownload
import NoxState

struct DownloadDetailsView: View {
    let taskID: UUID
    @ObservedObject var appState: AppState
    @ObservedObject var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss

    private var record: DownloadRecord? { appState.downloads.first { $0.id == taskID } }

    var body: some View {
        NavigationStack {
            List {
                if let r = record {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: "doc.richtext")
                                .font(.title).foregroundStyle(.tint)
                            Text(r.displayFilename).font(.headline).textSelection(.enabled)
                            Text(r.displayQuality + " · " + r.format.uppercased())
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    Section(L("任务")) {
                        detail("任务 ID", r.id.uuidString)
                        detail("状态", status(r.status))
                        if manager.missingFileIDs.contains(r.id) { detail("文件", L("文件缺失")) }
                        detail("进度", "\(Int(r.progress * 100))%")
                        detail("已下载", r.receivedBytes.map(TransferStats.formattedSize))
                        detail("文件总大小", r.totalBytes.map(TransferStats.formattedSize))
                        detail("分片数量", r.segmentCount.map(String.init))
                        detail("并发数", r.threadCount.map(String.init))
                        detail("失败原因", r.errorMessage)
                    }
                    Section(L("来源与解析")) {
                        detail("来源网页", r.metadata?.originalPageURL?.absoluteString ?? r.refererURL?.absoluteString)
                        detail("最终来源网页", r.metadata?.finalPageURL?.absoluteString)
                        detail("规范化来源网页", r.metadata?.normalizedPageURL?.absoluteString)
                        detail("规范化规则", r.metadata?.normalizationRule)
                        detail("解析脚本", r.metadata?.parserName)
                        detail("解析方式", r.metadata?.parsingMethod.map { L($0 == "sniffer" ? "通用嗅探" : "脚本解析") })
                        detail("视频 ID", r.metadata?.videoID)
                    }
                    Section(L("视频规格")) {
                        detail("清晰度", r.displayQuality)
                        detail("格式", r.format.uppercased())
                        detail("宽度", r.metadata?.width.map(String.init))
                        detail("高度", r.metadata?.height.map(String.init))
                        detail("时长（秒）", r.metadata?.duration.map { String(format: "%.2f", $0) })
                        detail("视频编码", r.metadata?.videoCodec)
                        detail("音频编码", r.metadata?.audioCodec)
                        detail("帧率", r.metadata?.frameRate.map { String(format: "%.2f", $0) })
                        detail("码率", r.metadata?.bitrate.map { "\($0) bit/s" })
                        detail("音轨语言", r.metadata?.audioLanguage)
                        detail("字幕语言", r.metadata?.subtitleLanguage)
                    }
                    Section(L("时间记录")) {
                        detail("创建时间", date(r.createdAt))
                        detail("完成时间", r.metadata?.completedAt.map(date))
                        if let dates = r.metadata?.updateDates, !dates.isEmpty {
                            ForEach(Array(dates.enumerated()), id: \.offset) { _, value in
                                detail("更新时间", date(value))
                            }
                        } else { detail("更新时间", nil) }
                    }
                    Section(L("文件")) {
                        detail("指定文件名", r.desiredFilename)
                        detail("保存文件名", r.fileName)
                        detail("文件地址", manager.shareableFileURL(for: r)?.path ?? r.fileURL?.path)
                    }
                    Section(L("下载请求")) {
                        detail("下载链接", r.sourceURL.absoluteString)
                        detail("Referer", r.refererURL?.absoluteString)
                        DisclosureGroup("Cookie") { detail("Cookie", r.cookieHeader) }
                        if let headers = r.metadata?.requestHeaders {
                            ForEach(headers.keys.sorted(), id: \.self) { key in
                                detail(key, headers[key])
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L("详细信息"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("完成")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func detail(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L(title)).font(.subheadline).foregroundStyle(.secondary)
            Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? L("未获取"))
                .font(.body).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }
    private func date(_ value: Date) -> String {
        value.formatted(date: .abbreviated, time: .standard)
    }
    private func status(_ status: DownloadStatus) -> String {
        switch status {
        case .queued: return L("排队中")
        case .downloading: return L("下载中")
        case .paused: return L("已暂停")
        case .finished: return L("已完成")
        case .failed: return L("失败")
        case .notStarted, .legacyCancelled: return L("未开始")
        }
    }
}
