import AVFoundation
import Foundation
import NoxCore
import NoxKeepAlive

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
        /// (媒体进度, 已下载字节, 估算总字节)
        let progress: (Double, Int64, Int64) -> Void
    }

    /// AVAsset 不暴露逐字节进度，iOS 26 的 metric event 会给出每个
    /// playlist / segment 请求的实际响应体字节数；这里按任务累计。
    private struct ByteState {
        var downloaded: Int64 = 0
        var estimatedTotal: Int64 = 0
        var totalDuration: Double = 0
        var loadedDuration: Double = 0
        var seenRequests: Set<String> = []
    }

    private var contexts: [Int: Context] = [:]
    private var byteStates: [Int: ByteState] = [:]
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
        progress: @escaping (Double, Int64, Int64) -> Void
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
            let identifier = task.taskIdentifier
            contexts[identifier] = Context(
                recordID: recordID,
                continuation: continuation,
                task: task,
                progress: progress
            )
            byteStates[identifier] = ByteState()
            taskIdentifiers[recordID] = identifier
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
        byteStates.removeValue(forKey: identifier)
        context.task.cancel()
        context.continuation.resume(throwing: CancellationError())
    }

    // MARK: - 字节统计

    @MainActor
    private func updateTimeProgress(
        identifier: Int,
        loaded: Double,
        expected: Double
    ) {
        guard var state = byteStates[identifier],
              let context = contexts[identifier] else { return }

        state.totalDuration = expected
        state.loadedDuration = min(max(loaded, 0), expected)
        refreshEstimate(&state)
        byteStates[identifier] = state
        context.progress(fraction(of: state), state.downloaded, state.estimatedTotal)
    }

    @available(iOS 26.0, *)
    @MainActor
    private func handle(metricEvent: AVMetricEvent, identifier: Int) {
        guard var state = byteStates[identifier],
              let context = contexts[identifier] else { return }

        // 任务结束时的汇总事件给出精确总字节数，用来校正累计值。
        if let summary = metricEvent as? AVMetricDownloadSummaryEvent {
            let total = Int64(max(summary.bytesDownloadedCount, 0))
            state.downloaded = max(state.downloaded, total)
            state.estimatedTotal = max(state.estimatedTotal, state.downloaded)
            byteStates[identifier] = state
            context.progress(fraction(of: state), state.downloaded, state.estimatedTotal)
            return
        }

        guard let request = Self.resourceRequest(from: metricEvent) else { return }

        let key = Self.metricKey(for: request)
        guard state.seenRequests.insert(key).inserted else { return }

        state.downloaded += max(Self.receivedBytes(from: request), 0)
        refreshEstimate(&state)
        byteStates[identifier] = state
        context.progress(fraction(of: state), state.downloaded, state.estimatedTotal)
    }

    @MainActor
    private func fraction(of state: ByteState) -> Double {
        guard state.totalDuration > 0 else { return 0 }
        return min(max(state.loadedDuration / state.totalDuration, 0), 1)
    }

    /// 已下载字节 / 已加载媒体比例 = 估算总字节数。
    /// 指数平滑避免「总大小」每秒来回跳动。
    @MainActor
    private func refreshEstimate(_ state: inout ByteState) {
        guard state.downloaded > 0,
              state.loadedDuration > 0,
              state.totalDuration > 0 else {
            return
        }

        let ratio = min(max(state.loadedDuration / state.totalDuration, 0.02), 1)
        let raw = Int64((Double(state.downloaded) / ratio).rounded())

        if state.estimatedTotal <= 0 {
            state.estimatedTotal = raw
        } else {
            state.estimatedTotal = Int64(
                (Double(state.estimatedTotal) * 0.75 + Double(raw) * 0.25).rounded()
            )
        }

        state.estimatedTotal = max(state.estimatedTotal, state.downloaded)
    }

    @available(iOS 18.0, *)
    private nonisolated static func resourceRequest(
        from event: AVMetricEvent
    ) -> AVMetricMediaResourceRequestEvent? {
        if let segment = event as? AVMetricHLSMediaSegmentRequestEvent {
            return segment.mediaResourceRequestEvent
        }
        if let playlist = event as? AVMetricHLSPlaylistRequestEvent {
            return playlist.mediaResourceRequestEvent
        }
        return event as? AVMetricMediaResourceRequestEvent
    }

    @available(iOS 18.0, *)
    private nonisolated static func receivedBytes(
        from request: AVMetricMediaResourceRequestEvent
    ) -> Int64 {
        let transactions = request.networkTransactionMetrics?.transactionMetrics ?? []
        return transactions.reduce(Int64(0)) { partial, transaction in
            partial + max(transaction.countOfResponseBodyBytesReceived, 0)
        }
    }

    @available(iOS 18.0, *)
    private nonisolated static func metricKey(
        for request: AVMetricMediaResourceRequestEvent
    ) -> String {
        let url = request.url?.absoluteString ?? ""
        let start = request.requestStartTime.timeIntervalSince1970
        let range = request.byteRange
        return "\(url)|\(start)|\(range.location)|\(range.length)"
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
        byteStates.removeValue(forKey: identifier)
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

        let grace = BackgroundExecutionGrace.shared.begin(reason: "AVAsset 导出")
        defer {
            if let grace {
                BackgroundExecutionGrace.shared.end(grace, reason: "AVAsset 导出")
            }
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
        let identifier = assetDownloadTask.taskIdentifier

        Task { @MainActor in
            self.updateTimeProgress(
                identifier: identifier,
                loaded: loaded,
                expected: expected
            )
        }
    }

    /// iOS 26 起每个 playlist / segment 请求都会回调 metric event，
    /// 其中 `networkTransactionMetrics` 带有实际响应体字节数。
    @available(iOS 26.0, *)
    nonisolated func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didReceive metricEvent: AVMetricEvent
    ) {
        let identifier = assetDownloadTask.taskIdentifier
        Task { @MainActor in
            self.handle(metricEvent: metricEvent, identifier: identifier)
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
        byteStates.removeValue(forKey: identifier)
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
