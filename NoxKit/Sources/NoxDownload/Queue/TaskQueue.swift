import Combine
import Foundation
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive

// MARK: - 任务级调度与启动

extension DownloadManager {
    // MARK: - 任务级调度

    /// 把任务加入等待队列。任务真正何时开始统一由 `reconcileTaskQueue` 决定。
    func start(_ record: DownloadRecord) {
        enqueueForSlot(record.id)
        reconcileTaskQueue(reason: "start")

        if pendingQueue.contains(record.id) {
            LogStore.shared.info(
                "queue wait \(record.displayFilename) · active \(activeIDs.count)/\(maxConcurrentTasks) · waiting \(pendingQueue.count)"
            )
        }
    }

    private func enqueueForSlot(_ id: UUID) {
        guard !activeIDs.contains(id), !pendingQueue.contains(id) else { return }
        pendingQueue.append(id)
    }

    func removeFromQueue(_ id: UUID) {
        pendingQueue.removeAll { $0 == id }
    }

    /// 当前这次下载尝试是否仍然有效。
    ///
    /// 每次真正占槽启动都会生成新令牌。暂停 / 删除 / 重试会移除令牌，
    /// 于是旧 run 迟到的探测结果、URLSession 回调和合并结果都会自动作废。
    func isCurrentRun(_ id: UUID, token: UUID) -> Bool {
        runTokens[id] == token
    }

    /// 让某个任务当前这次尝试失效，并取消它的调度句柄与网络请求。
    ///
    /// 只改调度状态，不碰下载记录本身；调用方负责随后写入新的用户状态
    /// （暂停 / 删除 / 重试）。
    func invalidateRun(for id: UUID) {
        runTokens.removeValue(forKey: id)
        slotTasks[id]?.cancel()
        slotTasks.removeValue(forKey: id)

        let identifiers = contexts
            .filter { $0.value.recordID == id }
            .map(\.key)

        for identifier in identifiers {
            contexts[identifier]?.task.cancel()
            contexts.removeValue(forKey: identifier)
        }
    }

    /// 让调度器的内部状态与持久化记录重新对齐。
    ///
    /// `store.downloads` 里的 `status` 是唯一事实来源：
    /// - `.queued` 等待槽位；
    /// - `.downloading` 表示已经拿到槽位；
    /// - 其余终态必须立刻释放槽位。
    ///
    /// 这样无论任务是正常完成、暂停、删除，还是 App 重启后恢复，都不会留下
    /// 「已经结束却还占着并发名额」的幽灵 ID；排队任务也会在每次状态变化后自动补位。
    func reconcileTaskQueue(reason: String? = nil) {
        guard !isReconcilingQueue else { return }
        isReconcilingQueue = true
        defer { isReconcilingQueue = false }

        var records = Dictionary(
            store.downloads.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let oldActiveCount = activeIDs.count
        let oldWaitingCount = pendingQueue.count

        // 1. 释放已删除 / 已结束 / 缺少有效 run 的槽位。
        //    `queued` 也允许处于 active：任务已经从队列取出、但 `begin` 还没把它
        //    标成 downloading，这中间不能让别的 reconcile 把槽位抢走。
        for id in Array(activeIDs) {
            guard let record = records[id] else {
                dropActiveSlot(id)
                continue
            }

            guard !record.status.isTerminal else {
                dropActiveSlot(id)
                continue
            }

            guard runTokens[id] != nil else {
                dropActiveSlot(id)
                continue
            }
        }

        // 2. 自愈：状态是「下载中」，但调度器已经没有对应槽位 / run。
        //    典型来源是旧版本遗漏了补位、或某个完成回调丢失。把它放回排队，
        //    重新探测并按磁盘上的分片续传，而不是永远卡在「下载中」。
        for record in store.downloads
        where record.status == .downloading && !activeIDs.contains(record.id) {
            var recovered = record
            recovered.status = .queued
            recovered.errorMessage = nil
            store.updateDownload(recovered)
            records[recovered.id] = recovered
            LogStore.shared.warning("queue recover \(recovered.displayFilename)")
        }

        // 3. 清掉已经不在等待状态、已经拿到槽位或已经不存在的队列项。
        pendingQueue.removeAll { id in
            guard let record = records[id] else { return true }
            return record.status != .queued
                || activeIDs.contains(id)
                || runTokens[id] != nil
        }

        // 4. 接管没有进入 pendingQueue 的排队任务。典型场景：App 被系统回收
        //    后重新启动，持久化记录里的 .queued 需要重新排进调度器。
        let orphaned = store.downloads
            .filter {
                $0.status == .queued
                    && !activeIDs.contains($0.id)
                    && !pendingQueue.contains($0.id)
            }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        pendingQueue.append(contentsOf: orphaned.map(\.id))

        // 5. 按 FIFO 补满空闲槽位。调小上限时不打断正在跑的任务，
        //    只让 active 数自然降到新上限以下后再继续取队列。
        while activeIDs.count < maxConcurrentTasks, !pendingQueue.isEmpty {
            let id = pendingQueue.removeFirst()

            guard let record = records[id], record.status == .queued else { continue }
            guard !activeIDs.contains(id), runTokens[id] == nil else { continue }

            let token = UUID()
            runTokens[id] = token
            activeIDs.insert(id)

            LogStore.shared.info(
                "queue start \(record.displayFilename) · active \(activeIDs.count)/\(maxConcurrentTasks)"
            )

            slotTasks[id] = Task { [weak self] in
                guard let self else { return }
                await self.begin(record, token: token)

                // begin 返回 ≠ 下载结束：普通下载此时分片还在飞，
                // 要等 assemble / abort 把它推进终态才释放槽位。
                self.releaseSlotIfSettled(id, token: token)
            }
        }

        if oldActiveCount != activeIDs.count || oldWaitingCount != pendingQueue.count {
            LogStore.shared.info(
                "queue \(reason ?? "reconcile") · active \(activeIDs.count)/\(maxConcurrentTasks) · waiting \(pendingQueue.count)"
            )
        }
    }

    /// 丢弃一个已经不可信的槽位：取消调度 / 网络请求，并清掉该任务的分片调度状态。
    private func dropActiveSlot(_ id: UUID) {
        invalidateRun(for: id)
        resetScheduling(for: id)
        clearTransferStats(for: id)
        releaseSlotWithoutPump(id)
    }

    func releaseSlotIfSettled(_ id: UUID, token: UUID) {
        // 旧 run 结束时新 run 可能已经拿到槽位，绝不能替新 run 释放。
        guard isCurrentRun(id, token: token) else { return }

        guard let status = store.downloads.first(where: { $0.id == id })?.status else {
            releaseSlot(id, token: token)
            return
        }

        // 普通下载在 begin 返回时仍然是 .downloading，说明分片还在飞。
        // 其余状态（包括 .queued = begin 在真正启动前就退出了）都释放槽位。
        guard status == .downloading else {
            releaseSlot(id, token: token)
            return
        }
    }

    /// 释放槽位并补位。幂等：重复调用不会重复触发调度。
    func releaseSlot(_ id: UUID, token: UUID? = nil) {
        if let token, !isCurrentRun(id, token: token) { return }

        activeIDs.remove(id)
        let tokenMatches = token.map { isCurrentRun(id, token: $0) } ?? true
        if tokenMatches {
            runTokens.removeValue(forKey: id)
        }
        slotTasks.removeValue(forKey: id)

        reconcileTaskQueue(reason: "release")
    }

    /// 只清理槽位，不触发新的调度。调用方正在统一重排时使用，避免递归。
    func releaseSlotWithoutPump(_ id: UUID, token: UUID? = nil) {
        if let token, !isCurrentRun(id, token: token) { return }

        activeIDs.remove(id)
        let tokenMatches = token.map { isCurrentRun(id, token: $0) } ?? true
        if tokenMatches {
            runTokens.removeValue(forKey: id)
        }
        slotTasks.removeValue(forKey: id)
    }

    // MARK: - 启动流程

    func begin(_ record: DownloadRecord, token: UUID) async {
        // 排队期间被暂停 / 删除 / 重试：令牌已经失效，直接退出。
        guard isCurrentRun(record.id, token: token) else { return }
        guard let live = store.downloads.first(where: { $0.id == record.id }),
              live.status == .queued else {
            releaseSlot(record.id, token: token)
            return
        }

        // m3u8 走独立管线：清单 → 分片 → AES-128 解密 → 合并。
        // 它的总大小事先未知、分片数量由清单决定，套用字节分片逻辑没有意义。
        if live.format.lowercased() == "m3u8" {
            await beginHLS(live, token: token)
            return
        }

        let id = record.id

        var updated = live
        updated.status = .downloading
        updated.errorMessage = nil
        store.updateDownload(updated)

        // 先把统计挂上，探测期间列表不会空着
        let resumeBytes = live.receivedBytes ?? 0
        transfers[id] = TransferStats(
            bytesReceived: resumeBytes,
            totalBytes: live.totalBytes ?? 0
        )
        speedMeters[id] = nil

        startProgressTimerIfNeeded()

        let probe = await Self.probe(
            url: live.sourceURL,
            referer: live.refererURL,
            cookieHeader: live.cookieHeader,
            allowsCellularAccess: allowsCellularDownloads
        )

        guard isCurrentRun(id, token: token) else { return }

        // 探测失败时**不要**动分片目录：已经下好的分片仍然是有效的，
        // 清掉就等于让用户白白重下。error 里已区分「链接失效」与「网络抖动」。
        if let probeError = probe.error {
            abort(id: id, token: token, message: probeError)
            return
        }

        let partsDirectory = DownloadStorage.partsDirectory(for: id)

        // 服务器不支持 Range（返回 200）→ 只能整文件重下，无法续传
        guard probe.supportsRanges, let totalBytes = probe.totalBytes, totalBytes > 0 else {
            try? FileManager.default.removeItem(at: partsDirectory)
            try? FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)

            schedule(
                record: updated,
                token: token,
                segments: [DownloadSegment(index: 0, start: 0, length: 0)],
                totalBytes: 0,
                concurrency: 1
            )
            return
        }

        let segments = Self.makeSegments(totalBytes: totalBytes)

        // 续传判据：远端大小一致、分片布局一致、分片目录还在。
        // 任何一条不满足就整批作废，避免把不对齐的分片拼成损坏文件。
        let resumable = live.totalBytes == totalBytes
            && live.segmentCount == segments.count
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
            token: token,
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
