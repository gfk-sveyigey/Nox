import Combine
import Foundation
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive

// MARK: - 任务级调度与启动

extension DownloadManager {
    // MARK: - 任务级调度

    func start(_ record: DownloadRecord) {
        guard !activeIDs.contains(record.id), !pendingQueue.contains(record.id) else { return }

        pendingQueue.append(record.id)
        drainQueue()
    }

    func drainQueue() {
        while activeIDs.count < maxConcurrentTasks, !pendingQueue.isEmpty {
            let id = pendingQueue.removeFirst()

            guard let record = store.downloads.first(where: { $0.id == id }) else { continue }

            activeIDs.insert(id)

            slotTasks[id] = Task { [weak self] in
                await self?.begin(record)

                // begin 返回 ≠ 下载结束：普通下载此时分片还在飞，
                // 要等 assemble / abort 把它推进终态才释放槽位。
                self?.releaseSlotIfSettled(id)
            }
        }
    }

    func releaseSlotIfSettled(_ id: UUID) {
        guard let status = store.downloads.first(where: { $0.id == id })?.status else {
            releaseSlot(id)
            return
        }

        guard status != .queued, status != .downloading else { return }
        releaseSlot(id)
    }

    /// 幂等：重复调用不会重复触发 `drainQueue`。
    func releaseSlot(_ id: UUID) {
        guard activeIDs.remove(id) != nil else { return }

        slotTasks.removeValue(forKey: id)
        drainQueue()
    }

    // MARK: - 启动流程

    func begin(_ record: DownloadRecord) async {
        // 排队期间被取消：调度句柄已被 cancel，直接退出。
        // 必须在清除 cancellingIDs 之前判断，否则会把这个取消标记抹掉。
        if Task.isCancelled { return }

        // m3u8 走独立管线：清单 → 分片 → AES-128 解密 → 合并。
        // 它的总大小事先未知、分片数量由清单决定，套用字节分片逻辑没有意义。
        if record.format.lowercased() == "m3u8" {
            await beginHLS(record)
            return
        }

        let id = record.id
        cancellingIDs.remove(id)

        var updated = record
        updated.status = .downloading
        updated.errorMessage = nil
        store.updateDownload(updated)

        // 先把统计挂上，探测期间列表不会空着
        let resumeBytes = record.receivedBytes ?? 0
        transfers[id] = TransferStats(
            bytesReceived: resumeBytes,
            totalBytes: record.totalBytes ?? 0
        )
        speedMeters[id] = nil

        startProgressTimerIfNeeded()

        let probe = await Self.probe(
            url: record.sourceURL,
            referer: record.refererURL,
            cookieHeader: record.cookieHeader
        )

        guard !cancellingIDs.contains(id) else { return }

        // 探测失败时**不要**动分片目录：已经下好的分片仍然是有效的，
        // 清掉就等于让用户白白重下。error 里已区分「链接失效」与「网络抖动」。
        if let probeError = probe.error {
            abort(id: id, message: probeError)
            return
        }

        let partsDirectory = DownloadStorage.partsDirectory(for: id)

        // 服务器不支持 Range（返回 200）→ 只能整文件重下，无法续传
        guard probe.supportsRanges, let totalBytes = probe.totalBytes, totalBytes > 0 else {
            try? FileManager.default.removeItem(at: partsDirectory)
            try? FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)

            schedule(
                record: updated,
                segments: [DownloadSegment(index: 0, start: 0, length: 0)],
                totalBytes: 0,
                concurrency: 1
            )
            return
        }

        let segments = Self.makeSegments(totalBytes: totalBytes)

        // 续传判据：远端大小一致、分片布局一致、分片目录还在。
        // 任何一条不满足就整批作废，避免把不对齐的分片拼成损坏文件。
        let resumable = record.totalBytes == totalBytes
            && record.segmentCount == segments.count
            && FileManager.default.fileExists(atPath: partsDirectory.path)

        if !resumable {
            try? FileManager.default.removeItem(at: partsDirectory)
        }

        try? FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)

        let concurrency = store.experimentalMultiThreadDownload
            ? max(1, min(store.multiThreadSegmentCount, NoxDefaults.segmentCountRange.upperBound))
            : 1

        schedule(
            record: updated,
            segments: segments,
            totalBytes: totalBytes,
            concurrency: concurrency
        )
    }

    /// 按固定长度均分。数量只取决于总大小，因此线程数变化不会让旧分片失效。
    static func makeSegments(totalBytes: Int64) -> [DownloadSegment] {
        guard totalBytes > 0 else {
            return [DownloadSegment(index: 0, start: 0, length: 0)]
        }

        let count = Int((totalBytes + segmentLength - 1) / segmentLength)

        var segments: [DownloadSegment] = []
        segments.reserveCapacity(count)

        var start: Int64 = 0

        for index in 0..<count {
            let end = min(start + segmentLength, totalBytes)
            segments.append(DownloadSegment(index: index, start: start, length: end - start))
            start = end
        }

        return segments
    }
}
