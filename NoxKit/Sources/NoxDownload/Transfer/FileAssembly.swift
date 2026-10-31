import Combine
import Foundation
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive

// MARK: - 分片合并

extension DownloadManager {
    func assemble(
        recordID: UUID,
        segments: [DownloadSegment],
        partsDirectory: URL
    ) async {
        // 同一任务只允许合并一次。合并要读写整份文件、可能持续很久，
        // 期间若被再次触发（多个分片几乎同时收尾、或重试）就会各写一份成品，
        // 于是同一个任务冒出多个大小、时长都不同的文件。
        guard assemblingIDs.insert(recordID).inserted else { return }

        defer {
            assemblingIDs.remove(recordID)
            resetScheduling(for: recordID)
            releaseSlot(recordID)
        }

        guard var record = store.downloads.first(where: { $0.id == recordID }) else { return }
        // 已取消 / 已完成都不该再合并
        guard record.status != .cancelled, record.status != .finished else { return }

        let documentsDirectory = DownloadStorage.documentsDirectory
        let stagingDirectory = DownloadStorage.stagingDirectory(for: recordID)

        var failure: String?

        do {
            try FileManager.default.createDirectory(
                at: documentsDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )

            let fallback = "\(record.title)-\(record.quality).\(Self.fileExtension(for: record.format))"
            let filename = Self.uniqueFilename(record.desiredFilename ?? fallback)

            let destination = documentsDirectory
                .appendingPathComponent(filename)

            let parts = segments
                .sorted { $0.index < $1.index }
                .map { DownloadStorage.partURL(in: partsDirectory, index: $0.index) }

            // 先拼到暂存目录，再整体移到 Documents：
            // 中途进程被杀时留下的只是暂存文件，不会残留半截成品 ——
            // 否则下次合并会另生成一个新文件，看起来就是「重复合片」。
            let temporary = stagingDirectory
                .appendingPathComponent("merged-\(UUID().uuidString).tmp")

            try await Task.detached(priority: .utility) {
                try DownloadStorage.concatenate(parts, into: temporary)
            }.value

            // 合并期间用户取消了：不要再写成「已完成」，避免覆盖取消状态
            guard !cancellingIDs.contains(recordID) else {
                try? FileManager.default.removeItem(at: temporary)
                return
            }

            // 分片齐全但拼出来的大小对不上，说明磁盘上的分片已经和远端不一致
            // （链接过期、文件被替换等），不能当成成功。
            if let total = record.totalBytes, total > 0,
               DownloadStorage.fileSize(at: temporary) != total {
                try? FileManager.default.removeItem(at: temporary)
                failure = L("合并后的文件大小与预期不符，请重新下载。")
            } else {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)

                record.fileName = filename
                record.fileURL = destination
                record.status = .finished
                record.progress = 1
                record.errorMessage = nil
                if let total = record.totalBytes {
                    record.receivedBytes = total
                }
            }
        } catch {
            failure = String(format: L("保存文件失败：%@"), error.localizedDescription)
        }

        if let failure {
            record.status = .failed
            record.errorMessage = failure
            // 失败时保留分片，方便重试续传；只清掉暂存
            try? FileManager.default.removeItem(at: stagingDirectory)
            clearTransferStats(for: recordID)
            store.updateDownload(record)
            logCompletion(record)
            return
        }

        try? FileManager.default.removeItem(at: partsDirectory)
        try? FileManager.default.removeItem(at: stagingDirectory)

        clearTransferStats(for: recordID)
        store.updateDownload(record)
        logCompletion(record)
    }
}
