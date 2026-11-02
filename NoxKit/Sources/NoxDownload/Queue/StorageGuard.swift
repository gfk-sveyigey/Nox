import Foundation
import NoxCore

// MARK: - 储存保护

extension DownloadManager {
    /// 整机剩余空间是否低于用户设置的最低保留值。
    var isBelowStorageThreshold: Bool {
        let threshold = store.minFreeDiskSpace
        guard threshold > 0 else { return false }
        let usage = DeviceStorage.usage()
        // 拿不到容量信息时不要误判成「空间不足」，否则会把队列全部卡住。
        guard usage.totalBytes > 0 else { return false }
        return usage.freeBytes < threshold
    }

    /// 重新检查储存保护。返回 true 表示当前被限制，调用方应停止启动新任务。
    @discardableResult
    func refreshStorageBlockState(reason: String? = nil) -> Bool {
        let threshold = store.minFreeDiskSpace
        guard threshold > 0 else {
            if storageBlocked {
                storageBlocked = false
                LogStore.shared.info("storage guard disabled")
            }
            return false
        }

        let usage = DeviceStorage.usage()
        guard usage.totalBytes > 0 else { return false }
        let free = usage.freeBytes
        guard free < threshold else {
            if storageBlocked {
                storageBlocked = false
                LogStore.shared.info(
                    "storage guard cleared · free \(TransferStats.formattedSize(free))"
                )
            }
            return false
        }

        if !storageBlocked {
            storageBlocked = true
            LogStore.shared.warning(
                "storage guard active · free \(TransferStats.formattedSize(free)) < \(TransferStats.formattedSize(threshold))"
            )
        }

        // 正在跑的请求也停下来，避免继续把最后一点空间写满。
        // 排队中的任务保留 .queued，等空间恢复后再由 reconcile 拉起。
        pauseActiveForLowStorage()
        if let reason {
            LogStore.shared.info("storage guard paused active tasks (\(reason))")
        }
        return true
    }

    /// 暂停所有已经拿到槽位 / 正在探测或下载的任务。
    func pauseActiveForLowStorage() {
        let targets = store.downloads.filter { activeIDs.contains($0.id) }
        guard !targets.isEmpty else { return }

        let message = L("储存空间不足，下载已暂停。释放空间后会继续排队任务。")
        for record in targets {
            performCancel(record, errorMessage: message)
        }
        pendingQueue.removeAll { id in
            guard let record = store.downloads.first(where: { $0.id == id }) else {
                return true
            }
            return record.status != .queued
        }
    }
}
