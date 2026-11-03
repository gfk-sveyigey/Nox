import Combine
import Foundation
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive

// MARK: - 进度与速度

extension DownloadManager {
    // MARK: - 进度 / 速度

    func startProgressTimerIfNeeded() {
        guard progressTimer == nil else { return }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickProgress()
            }
        }

        // 必须加到 .common，否则滚动列表时计时器暂停、进度会卡住
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    func tickProgress() {
        // 储存保护：每 3 秒检查一次整机剩余空间。低于阈值时立即暂停
        // 正在下载的任务，避免继续把设备写满。
        if Date().timeIntervalSince(lastStorageCheck) >= 3 {
            lastStorageCheck = .now
            if isBelowStorageThreshold {
                if !storageBlocked {
                    storageBlocked = true
                    LogStore.shared.warning("storage guard reached during download")
                }
                if !activeIDs.isEmpty {
                    pauseActiveForLowStorage()
                    reconcileTaskQueue(reason: "storage")
                    return
                }
            } else if storageBlocked {
                storageBlocked = false
                LogStore.shared.info("storage guard cleared during download")
                reconcileTaskQueue(reason: "storage")
            }
        }

        // 以「记录状态」而不是 contexts 判断是否还有任务。
        // begin() 里要等 probe 返回才会创建 task，若用 contexts 判断，
        // 探测超过 1 秒时第一次 tick 就会把计时器停掉，此后进度与速度再也不更新。
        let activeRecords = store.downloads.filter { $0.status == .downloading }

        guard !activeRecords.isEmpty else {
            stopProgressTimer()
            // 兜底：如果有任务结束回调丢失，activeIDs 里可能还留着幽灵槽位。
            // 定时器停之前统一对齐一次，让排队任务能补上空出来的位置。
            reconcileTaskQueue(reason: "idle")
            return
        }

        // 本次运行中、尚未追加到分片文件的字节数
        var inFlightBytes: [UUID: Int64] = [:]
        for context in contexts.values {
            inFlightBytes[context.recordID, default: 0] += max(context.task.countOfBytesReceived, 0)
        }

        for record in activeRecords {
            let id = record.id

            // 只有当前 run 还活着的记录才更新实时统计。状态已变成下载中但
            // 调度器没有对应 run 的情况，交给下一次 reconcile 自愈。
            guard runTokens[id] != nil else { continue }

            let isHLS = record.format.lowercased() == "m3u8"

            let received: Int64
            let total: Int64

            if isHLS {
                // m3u8 的字节数来自分片累计；总大小按已完成进度估算。
                guard let snapshot = hlsProgress[id] else { continue }
                received = snapshot.bytes
                total = snapshot.estimatedTotalBytes
            } else {
                let inFlight = inFlightBytes[id] ?? 0
                let segments = plannedSegments[id] ?? []
                let onDisk = DownloadStorage.totalPartSize(
                    segments: segments,
                    in: DownloadStorage.partsDirectory(for: id)
                )
                received = onDisk + inFlight
                total = record.totalBytes ?? 0
            }

            // 速度统一在 1 秒节拍上算，而不是每次分片回调都算：
            // m3u8 的分片会在同一秒内成批完成，按回调时间戳算会得到一串
            // 极短的采样区间，速度因此剧烈抖动（表现为数字乱跳、明显偏大）。
            //
            // 具体数值交给 SpeedMeter：它用「累计字节 + 单调时钟」在滑动窗口内做首尾差分，
            // 并对时间断层（切回前台 / 长期无数据）与计数器回退自动重置。
            var meter = speedMeters[id] ?? SpeedMeter()
            let speed = meter.update(totalBytes: received, at: SpeedMeter.now())
            speedMeters[id] = meter

            transfers[id] = TransferStats(
                bytesReceived: received,
                totalBytes: total,
                bytesPerSecond: speed,
                isTotalEstimated: isHLS && total > 0
            )

            var updated = record
            updated.receivedBytes = received

            if isHLS {
                if let snapshot = hlsProgress[id], snapshot.total > 0 {
                    updated.progress = min(
                        Double(snapshot.completed) / Double(snapshot.total),
                        1
                    )
                }
            } else if total > 0 {
                updated.progress = min(Double(received) / Double(total), 1)
            }

            // 高频刷新只改内存，不写 UserDefaults
            store.updateDownload(updated, persist: false)
        }

        // 持续处理任务在系统界面里显示整体进度；把它同步给后台任务。
        if !activeIDs.isEmpty {
            let records = store.downloads.filter { activeIDs.contains($0.id) }
            if !records.isEmpty {
                let fraction = records.reduce(0.0) { $0 + $1.progress } / Double(records.count)
                keepAlive.updateProgress(fraction)
            }
        }
    }

    func clearTransferStats(for id: UUID) {
        transfers.removeValue(forKey: id)
        speedMeters.removeValue(forKey: id)
    }
}
