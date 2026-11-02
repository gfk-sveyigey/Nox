import AVFoundation
import Foundation
import NoxCore

/// 用系统 `AVAssetDownloadURLSession` 下载 HLS，再把系统产物导出为普通 MP4。
///
/// 这条路径不在 App 里逐片编排，后台调度、断点与清单更新由系统负责，
/// 适合长时间后台下载；代价是必须等下载结束再做一次转封装。
@MainActor
final class AVAssetHLSDownloader: NSObject {
    private struct Context {
        let recordID: UUID
        let continuation: CheckedContinuation<URL, Error>
        let task: AVAssetDownloadTask
        let progress: (Double) -> Void
    }

    private var contexts: [Int: Context] = [:]
    private var taskIdentifiers: [UUID: Int] = [:]
    private var session: AVAssetDownloadURLSession?
    private var sessionAllowsCellularAccess: Bool?

    nonisolated static let sessionIdentifier = "com.aholic.nox.hls.avasset"

    func download(
        recordID: UUID,
        playlistURL: URL,
        referer: URL?,
        cookieHeader: String?,
        title: String,
        allowsCellularAccess: Bool,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        let session = makeSession(allowsCellularAccess: allowsCellularAccess)

        var headers: [String: String] = [:]
        if let referer {
            headers["Referer"] = referer.absoluteString
        }
        if let cookieHeader, !cookieHeader.isEmpty {
            headers["Cookie"] = cookieHeader
        }

        var options: [String: Any] = [:]
        if !headers.isEmpty {
            // AVURLAsset 的请求头键没有被 Swift 以公开常量暴露，使用系统识别的字符串键。
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }

        let asset = AVURLAsset(url: playlistURL, options: options.isEmpty ? nil : options)
        guard let task = session.makeAssetDownloadTask(
            asset: asset,
            assetTitle: title,
            assetArtworkData: nil,
            options: nil
        ) else {
            throw AVAssetDownloadError.taskUnavailable
        }
        task.taskDescription = recordID.uuidString

        return try await withCheckedThrowingContinuation { continuation in
            contexts[task.taskIdentifier] = Context(
                recordID: recordID,
                continuation: continuation,
                task: task,
                progress: progress
            )
            taskIdentifiers[recordID] = task.taskIdentifier
            task.resume()
        }
    }

    /// App 被后台 URLSession 事件唤醒时，提前建立会话以接上系统回调。
    func prepareForBackgroundEvents(allowsCellularAccess: Bool) {
        _ = makeSession(allowsCellularAccess: allowsCellularAccess)
    }

    func cancel(recordID: UUID) {
        guard let identifier = taskIdentifiers.removeValue(forKey: recordID),
              let context = contexts.removeValue(forKey: identifier) else {
            return
        }
        context.task.cancel()
        context.continuation.resume(throwing: CancellationError())
    }

    private func makeSession(allowsCellularAccess: Bool) -> AVAssetDownloadURLSession {
        if let session, sessionAllowsCellularAccess == allowsCellularAccess {
            return session
        }

        // 已有任务在跑时不重建会话，避免把任务一起取消；新设置会在下一次生效。
        if !contexts.isEmpty, let session {
            return session
        }

        session?.invalidateAndCancel()

        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier
        )
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = allowsCellularAccess

        let created = AVAssetDownloadURLSession(
            configuration: configuration,
            assetDownloadDelegate: self,
            delegateQueue: .main
        )
        session = created
        sessionAllowsCellularAccess = allowsCellularAccess
        return created
    }

    private func finish(
        identifier: Int,
        localURL: URL
    ) async {
        guard let context = contexts.removeValue(forKey: identifier) else {
            try? FileManager.default.removeItem(at: localURL)
            return
        }
        taskIdentifiers.removeValue(forKey: context.recordID)

        do {
            let staging = DownloadStorage.stagingDirectory(for: context.recordID)
                .appendingPathComponent("avasset", isDirectory: true)
            try FileManager.default.createDirectory(
                at: staging,
                withIntermediateDirectories: true
            )

            let destination = staging.appendingPathComponent(
                "export-\(UUID().uuidString).mp4"
            )
            try await export(localURL, to: destination)
            try? FileManager.default.removeItem(at: localURL)
            context.continuation.resume(returning: destination)
        } catch {
            try? FileManager.default.removeItem(at: localURL)
            context.continuation.resume(throwing: error)
        }
    }

    private func export(_ source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw AVAssetDownloadError.exportUnavailable
        }

        try? FileManager.default.removeItem(at: destination)
        exporter.outputURL = destination
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously {
                continuation.resume()
            }
        }

        guard exporter.status == .completed else {
            throw exporter.error ?? AVAssetDownloadError.exportFailed
        }
    }
}

extension AVAssetHLSDownloader: AVAssetDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange
    ) {
        let expected = CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
        guard expected.isFinite, expected > 0 else { return }

        let loaded = loadedTimeRanges.reduce(0.0) { partial, value in
            partial + CMTimeGetSeconds(value.timeRangeValue.duration)
        }
        let fraction = min(max(loaded / expected, 0), 1)
        let identifier = assetDownloadTask.taskIdentifier

        Task { @MainActor in
            self.contexts[identifier]?.progress(fraction)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let identifier = assetDownloadTask.taskIdentifier

        // 系统在代理方法返回后会回收 location，先复制到自己的暂存目录。
        guard let recordID = Self.recordID(from: assetDownloadTask) else { return }
        let staging = DownloadStorage.stagingDirectory(for: recordID)
            .appendingPathComponent("avasset", isDirectory: true)
        let copy = staging.appendingPathComponent(
            "download-\(UUID().uuidString).movpkg",
            isDirectory: true
        )

        do {
            try FileManager.default.createDirectory(
                at: staging,
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: location, to: copy)
        } catch {
            Task { @MainActor in
                self.fail(identifier: identifier, error: error)
            }
            return
        }

        Task { @MainActor in
            await self.finish(identifier: identifier, localURL: copy)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let identifier = task.taskIdentifier
        Task { @MainActor in
            self.fail(identifier: identifier, error: error)
        }
    }

    nonisolated func urlSessionDidFinishEvents(
        forBackgroundURLSession session: URLSession
    ) {
        let identifier = session.configuration.identifier ?? Self.sessionIdentifier
        BackgroundSessionEvents.shared.complete(identifier: identifier)
    }

    private nonisolated static func recordID(from task: URLSessionTask) -> UUID? {
        guard let description = task.taskDescription else { return nil }
        return UUID(uuidString: description)
    }

    @MainActor
    private func fail(identifier: Int, error: Error) {
        guard let context = contexts.removeValue(forKey: identifier) else { return }
        taskIdentifiers.removeValue(forKey: context.recordID)
        context.task.cancel()
        if error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
            context.continuation.resume(throwing: CancellationError())
        } else {
            context.continuation.resume(throwing: error)
        }
    }
}

private enum AVAssetDownloadError: LocalizedError {
    case taskUnavailable
    case exportUnavailable
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .taskUnavailable:
            return L("系统无法创建 AVAsset 下载任务。")
        case .exportUnavailable:
            return L("系统无法创建 AVAsset 导出会话。")
        case .exportFailed:
            return L("AVAsset 下载完成，但导出 MP4 失败。")
        }
    }
}
