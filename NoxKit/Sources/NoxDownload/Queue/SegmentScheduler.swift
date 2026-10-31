import Combine
import Foundation
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive

// MARK: - 分片调度

extension DownloadManager {
    /// 登记分片计划并启动第一批下载。
    func schedule(
        record: DownloadRecord,
        segments: [DownloadSegment],
        totalBytes: Int64,
        concurrency: Int
    ) {
        let id = record.id
        let partsDirectory = DownloadStorage.partsDirectory(for: id)

        var onDisk: Int64 = 0
        var pending: [Int] = []

        for segment in segments {
            let partURL = DownloadStorage.partURL(in: partsDirectory, index: segment.index)
            let existing = segment.length > 0
                ? min(DownloadStorage.fileSize(at: partURL), segment.length)
                : 0

            onDisk += existing

            if segment.length > 0, existing >= segment.length {
                completedSegments[id, default: []].insert(segment.index)
            } else {
                pending.append(segment.index)
            }
        }

        plannedSegments[id] = segments
        pendingSegments[id] = pending
        inFlightSegments[id] = 0
        recordConcurrency[id] = max(1, concurrency)

        var updated = record
        updated.totalBytes = totalBytes > 0 ? totalBytes : nil
        updated.segmentCount = segments.count
        updated.threadCount = max(1, concurrency)
        updated.receivedBytes = onDisk
        if totalBytes > 0 {
            updated.progress = min(Double(onDisk) / Double(totalBytes), 1)
        }
        updated.status = .downloading
        store.updateDownload(updated)

        transfers[id] = TransferStats(
            bytesReceived: onDisk,
            totalBytes: max(totalBytes, 0)
        )
        speedMeters[id] = nil

        pumpSegments(recordID: id)
        startProgressTimerIfNeeded()
    }

    /// 在并发上限内继续取分片开工；全部完成时收尾。
    func pumpSegments(recordID: UUID) {
        guard !cancellingIDs.contains(recordID) else { return }
        guard let segments = plannedSegments[recordID] else { return }

        let limit = recordConcurrency[recordID] ?? 1

        while (inFlightSegments[recordID] ?? 0) < limit {
            guard var queue = pendingSegments[recordID], !queue.isEmpty else { break }

            let index = queue.removeFirst()
            pendingSegments[recordID] = queue

            guard index < segments.count else { continue }
            startSegment(recordID: recordID, segment: segments[index], index: index)
        }

        if (pendingSegments[recordID] ?? []).isEmpty, (inFlightSegments[recordID] ?? 0) == 0 {
            Task { await finishIfComplete(recordID: recordID) }
        }
    }

    func startSegment(recordID: UUID, segment: DownloadSegment, index: Int) {
        guard let record = store.downloads.first(where: { $0.id == recordID }) else { return }

        let partsDirectory = DownloadStorage.partsDirectory(for: recordID)
        let partURL = DownloadStorage.partURL(in: partsDirectory, index: index)
        let existing = segment.length > 0
            ? min(DownloadStorage.fileSize(at: partURL), segment.length)
            : 0

        var request = URLRequest(url: record.sourceURL)
        request.httpMethod = "GET"
        request.allowsCellularAccess = allowsCellularDownloads
        request.setValue("video/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

        if let referer = record.refererURL {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }

        if let cookie = record.cookieHeader, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        // length == 0 表示「整文件单流」（服务器不支持 Range），此时不加 Range 头
        if segment.length > 0 {
            let end = segment.start + segment.length - 1
            request.setValue("bytes=\(segment.start + existing)-\(end)", forHTTPHeaderField: "Range")
        }

        let task = session.downloadTask(with: request)
        task.taskDescription = recordID.uuidString

        contexts[task.taskIdentifier] = SegmentContext(
            recordID: recordID,
            segmentIndex: index,
            partURL: partURL,
            alreadyWritten: existing,
            task: task
        )

        inFlightSegments[recordID, default: 0] += 1
        task.resume()
    }

    func resetScheduling(for id: UUID) {
        pendingSegments.removeValue(forKey: id)
        inFlightSegments.removeValue(forKey: id)
        recordConcurrency.removeValue(forKey: id)
        hlsProgress.removeValue(forKey: id)
        plannedSegments.removeValue(forKey: id)
        completedSegments.removeValue(forKey: id)
    }
}
