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

        // 「系统下载」模式下，HLS 分片交给后台 URLSession；其余保活方式沿用
        // 兼容分片引擎（URLSession.shared），由静音音频 / 画中画保持锁屏后的
        // 执行时间。两种方式都走自定义下载管线，不依赖 AVAsset 的系统活动。
        let segmentLoader: HLSDownloader.SegmentLoader?

        if store.keepAliveMode.usesBackgroundHLSSegments {
            segmentLoader = { [weak self] request, recordID, segmentIndex, manifestSignature in
                guard let self else { throw CancellationError() }
                return try await self.fetchHLSSegment(
                    request,
                    recordID: recordID,
                    segmentIndex: segmentIndex,
                    manifestSignature: manifestSignature
                )
            }
        } else {
            segmentLoader = nil
        }

        do {
            let merged = try await HLSDownloader(
                concurrency: concurrency,
                allowsCellularAccess: allowsCellularDownloads,
                segmentLoader: segmentLoader
            ).download(
                recordID: id,
                playlistURL: record.sourceURL,
                referer: record.refererURL,
                cookieHeader: record.cookieHeader,
                userAgent: nil
            ) { [weak self] progress in
                // 只记录，不在回调里算速度：分片常成批完成，
                // 由 1 秒定时器统一计算，速度才稳。
                Task { @MainActor in
                    guard let self, self.isCurrentRun(id, token: token) else { return }
                    self.hlsProgress[id] = progress
                    self.publishProgressIfNeeded()
                }
            }

            guard isCurrentRun(id, token: token) else {
                // 旧 run 失效：合并结果留在暂存目录。新的 run 会复用同一份
                // merged.mp4 和检查点，删掉反而要从头再拼一遍。
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

    /// 用后台 URLSession 下载单个 HLS 分片。
    ///
    /// 后台会话会在 App 挂起时继续传输；完成回调把数据交给 HLSDownloader
    /// 解密并写入 part 文件，因此重启后可以直接从磁盘续传。
    func fetchHLSSegment(
        _ request: URLRequest,
        recordID: UUID,
        segmentIndex: Int,
        manifestSignature: String
    ) async throws -> Data {
        let task = session.downloadTask(with: request)
        task.taskDescription = "hls:\(recordID.uuidString):\(segmentIndex):\(manifestSignature)"

        return try await withCheckedThrowingContinuation { continuation in
            hlsSegmentContexts[task.taskIdentifier] = HLSSegmentContext(
                recordID: recordID,
                task: task,
                continuation: continuation
            )
            task.resume()
        }
    }

    func finishHLS(recordID: UUID, token: UUID, mergedFile: URL) {
        guard isCurrentRun(recordID, token: token) else {
            // 合并结果保留在暂存目录，下一次 run 可以直接复用。
            return
        }

        defer {
            if isCurrentRun(recordID, token: token) {
                resetScheduling(for: recordID)
                releaseSlot(recordID, token: token)
            }
        }

        guard var record = store.downloads.first(where: { $0.id == recordID }) else { return }
        guard record.status != .paused, record.status != .notStarted, record.status != .finished else {
            // 已经完成（另一路 run 先收尾）：合并结果不再需要，清掉暂存。
            if record.status == .finished {
                try? FileManager.default.removeItem(
                    at: DownloadStorage.partsDirectory(for: recordID)
                )
                try? FileManager.default.removeItem(
                    at: DownloadStorage.stagingDirectory(for: recordID)
                )
            }
            return
        }

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
