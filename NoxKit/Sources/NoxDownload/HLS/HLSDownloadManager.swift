import Combine
import Foundation
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive

// MARK: - HLS 合并

extension DownloadManager {
    // MARK: - HLS（m3u8）

    func beginHLS(_ record: DownloadRecord, token: UUID) async {
        let id = record.id
        guard isCurrentRun(id, token: token) else { return }

        var updated = record
        updated.status = .downloading
        updated.errorMessage = nil

        // 复用「下载设置 → 多线程下载」：用户只需要理解一个并发旋钮。
        // m3u8 分片远小于字节分片（通常 2–10 秒一片、总数可达数百），
        // 所以再夹一道上限，避免打爆 CDN 触发限速或 403。
        let desired: Int

        if store.m3u8SegmentConcurrency > 0 {
            // 显式覆盖（0 表示跟随多线程设置）
            desired = store.m3u8SegmentConcurrency
        } else if store.experimentalMultiThreadDownload {
            desired = store.multiThreadSegmentCount
        } else {
            desired = NoxDefaults.defaultHLSConcurrency
        }

        let concurrency = min(max(desired, 1), NoxDefaults.maxHLSConcurrency)

        updated.threadCount = concurrency
        store.updateDownload(updated)

        transfers[id] = TransferStats()
        speedMeters[id] = nil
        hlsProgress.removeValue(forKey: id)
        startProgressTimerIfNeeded()

        do {
            let merged = try await HLSDownloader(
                concurrency: concurrency,
                allowsCellularAccess: allowsCellularDownloads
            ).download(
                recordID: id,
                playlistURL: record.sourceURL,
                referer: record.refererURL,
                cookieHeader: record.cookieHeader,
                userAgent: nil,
                quality: store.preferredQuality
            ) { [weak self] progress in
                // 只记录，不在回调里算速度：分片常成批完成，
                // 由 1 秒定时器统一计算，速度才稳。
                Task { @MainActor in
                    guard let self, self.isCurrentRun(id, token: token) else { return }
                    self.hlsProgress[id] = progress
                }
            }

            guard isCurrentRun(id, token: token) else {
                // 旧 run 失效后才下载完的临时合并文件没人接手，直接清掉
                try? FileManager.default.removeItem(at: merged)
                return
            }

            finishHLS(recordID: id, token: token, mergedFile: merged)
        } catch is CancellationError {
            // 暂停 / 删除 / 重试时令牌已失效，调用方已经改过状态并清了统计
            return
        } catch {
            guard isCurrentRun(id, token: token) else { return }
            abort(id: id, token: token, message: downloadErrorMessage(for: error))
        }
    }

    func finishHLS(recordID: UUID, token: UUID, mergedFile: URL) {
        guard isCurrentRun(recordID, token: token) else {
            try? FileManager.default.removeItem(at: mergedFile)
            return
        }

        defer {
            if isCurrentRun(recordID, token: token) {
                resetScheduling(for: recordID)
                releaseSlot(recordID, token: token)
            }
        }

        guard var record = store.downloads.first(where: { $0.id == recordID }) else { return }
        guard record.status != .cancelled, record.status != .finished else { return }

        do {
            let directory = DownloadStorage.documentsDirectory

            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            // 合并结果统一是 MP4 容器（TS / fMP4 分片拼接后由系统播放器识别）
            let fallback = "\(record.title)-\(record.quality).mp4"
            let filename = Self.uniqueFilename(record.desiredFilename ?? fallback)
            let destination = directory.appendingPathComponent(filename)

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: mergedFile, to: destination)

            // 合并结果是 0 字节说明清单/分片早就失效了，不能当成成功
            let mergedSize = DownloadStorage.fileSize(at: destination)
            if mergedSize == 0 {
                record.status = .failed
                record.errorMessage = L("合并后的文件为空，请重新下载。")
            } else {
                record.fileName = filename
                record.fileURL = destination
                record.status = .finished
                record.progress = 1
                record.errorMessage = nil
                record.receivedBytes = mergedSize
            }
        } catch {
            record.status = .failed
            record.errorMessage = String(format: L("保存文件失败：%@"), error.localizedDescription)
        }

        try? FileManager.default.removeItem(at: DownloadStorage.partsDirectory(for: recordID))
        try? FileManager.default.removeItem(at: DownloadStorage.stagingDirectory(for: recordID))

        clearTransferStats(for: recordID)
        store.updateDownload(record)
        logCompletion(record)
    }
}
