import Combine
import Foundation
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive

// MARK: - URLSession 回调

extension DownloadManager {
    // MARK: - URLSessionDownloadDelegate

    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard
            let idString = downloadTask.taskDescription,
            let recordID = UUID(uuidString: idString)
        else {
            return
        }

        let identifier = downloadTask.taskIdentifier

        // 服务器用 4xx/5xx 响应时，URLSession 仍会把响应体落成临时文件。
        // 不检查状态码就会把错误页当成视频存下来 —— 表现就是「任务成功但文件不对」。
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
            let statusCode = http.statusCode
            Task { @MainActor in
                guard let context = self.contexts[identifier] else { return }
                self.abort(
                    id: context.recordID,
                    token: context.runToken,
                    message: String(format: L("服务器返回错误：HTTP %d"), statusCode)
                )
            }
            return
        }

        // URLSession 的临时文件必须在本回调内消费掉，
        // 所以这里同步搬到 Staging，再回主线程追加到分片文件。
        let stagingDirectory = DownloadStorage.stagingDirectory(for: recordID)
        let stagingURL = stagingDirectory
            .appendingPathComponent("staging-\(identifier).part")

        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )

            try? FileManager.default.removeItem(at: stagingURL)
            try FileManager.default.copyItem(at: location, to: stagingURL)
        } catch {
            Task { @MainActor in
                guard let context = self.contexts[identifier] else { return }
                self.abort(
                    id: context.recordID,
                    token: context.runToken,
                    message: error.localizedDescription
                )
            }
            return
        }

        Task { @MainActor in
            await self.completeSegment(
                taskIdentifier: identifier,
                stagingURL: stagingURL,
                recordID: recordID
            )
        }
    }

    func completeSegment(
        taskIdentifier: Int,
        stagingURL: URL,
        recordID: UUID
    ) async {
        guard let context = contexts.removeValue(forKey: taskIdentifier),
              context.recordID == recordID else {
            try? FileManager.default.removeItem(at: stagingURL)
            return
        }

        let token = context.runToken

        // 暂停 / 删除 / 重试后旧请求可能刚好落地；它不能再改新 run 的分片状态。
        guard isCurrentRun(recordID, token: token) else {
            try? FileManager.default.removeItem(at: stagingURL)
            return
        }

        inFlightSegments[recordID] = max(0, (inFlightSegments[recordID] ?? 1) - 1)

        let partURL = context.partURL
        let segmentIndex = context.segmentIndex

        // 大文件追加放到后台线程，避免阻塞主线程
        let appended = await Task.detached(priority: .utility) {
            DownloadStorage.append(stagingURL, to: partURL)
        }.value

        try? FileManager.default.removeItem(at: stagingURL)

        // 追加是后台异步完成的，期间用户可能已经暂停 / 重试。
        guard isCurrentRun(recordID, token: token) else { return }

        guard appended else {
            abort(id: recordID, token: token, message: L("写入分片文件失败"))
            return
        }

        completedSegments[recordID, default: []].insert(segmentIndex)

        pumpSegments(recordID: recordID, token: token)
    }

    func finishIfComplete(recordID: UUID, token: UUID) async {
        guard isCurrentRun(recordID, token: token) else { return }
        guard let segments = plannedSegments[recordID], !segments.isEmpty else { return }

        let partsDirectory = DownloadStorage.partsDirectory(for: recordID)
        let completed = completedSegments[recordID] ?? []

        let allDone = segments.allSatisfy { segment in
            if completed.contains(segment.index) { return true }
            guard segment.length > 0 else { return false }
            return DownloadStorage.fileSize(
                at: DownloadStorage.partURL(in: partsDirectory, index: segment.index)
            ) >= segment.length
        }

        guard allDone else { return }

        await assemble(
            recordID: recordID,
            token: token,
            segments: segments,
            partsDirectory: partsDirectory
        )
    }

    public nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // 成功完成由 didFinishDownloadingTo 处理，这里只处理错误
        guard let error else { return }

        let identifier = task.taskIdentifier

        Task { @MainActor in
            guard let context = self.contexts.removeValue(forKey: identifier) else { return }
            guard self.isCurrentRun(context.recordID, token: context.runToken) else { return }

            self.abort(
                id: context.recordID,
                token: context.runToken,
                message: self.downloadErrorMessage(for: error)
            )
        }
    }

    public nonisolated func urlSessionDidFinishEvents(
        forBackgroundURLSession session: URLSession
    ) {}
}
