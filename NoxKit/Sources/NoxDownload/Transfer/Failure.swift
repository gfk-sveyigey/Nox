import Combine
import Foundation
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive

// MARK: - 失败处理

extension DownloadManager {
    func abort(id: UUID, message: String) {
        defer {
            resetScheduling(for: id)
            releaseSlot(id)
        }

        // 一个分片失败即整体失败；其余分片取消，但分片文件保留，方便重试续传
        let identifiers = contexts
            .filter { $0.value.recordID == id }
            .map(\.key)

        for identifier in identifiers {
            contexts[identifier]?.task.cancel()
            contexts.removeValue(forKey: identifier)
        }

        guard var record = store.downloads.first(where: { $0.id == id }) else { return }
        guard record.status == .downloading else { return }

        record.status = .failed
        record.errorMessage = String(format: L("下载失败：%@"), message)

        // 用磁盘上的分片数，而不是含「在飞字节」的统计值 ——
        // 后者会把还没落盘的字节算进去，重试时进度会先涨后跌。
        let segments = plannedSegments[id] ?? []
        let onDisk = DownloadStorage.totalPartSize(
            segments: segments,
            in: DownloadStorage.partsDirectory(for: id)
        )

        if onDisk > 0 {
            record.receivedBytes = onDisk
        }

        clearTransferStats(for: id)
        store.updateDownload(record)

        LogStore.shared.error("failed \(record.displayFilename): \(message)")
    }

    /// 记录一次任务结束（完成或保存失败）。
    func logCompletion(_ record: DownloadRecord) {
        if record.status == .finished {
            LogStore.shared.info("finished \(record.displayFilename) · \(TransferStats.formattedSize(record.receivedBytes ?? 0))")
        } else if let message = record.errorMessage {
            LogStore.shared.error("failed \(record.displayFilename): \(message)")
        }
    }
}
