import Foundation

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    @Published private(set) var state: DownloadState = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0

    private var session: URLSession!
    private var downloadTask: URLSessionDownloadTask?
    private var destinationURL: URL?
    private var baseFileName = "video"

    override init() {
        super.init()

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func start(url: URL, fileName: String, referer: URL?) {
        cancel()

        baseFileName = Self.sanitize(fileName)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60

        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }

        progress = 0
        downloadedBytes = 0
        totalBytes = 0
        state = .downloading

        downloadTask = session.downloadTask(with: request)
        downloadTask?.resume()
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil

        if state == .downloading {
            state = .idle
        }
    }

    func shareURL() -> URL? {
        destinationURL
    }

    private func finalURL() -> URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        return documents.appendingPathComponent(baseFileName + ".mp4")
    }

    private static func sanitize(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = title.components(separatedBy: invalid).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "video" : trimmed
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            self.downloadedBytes = totalBytesWritten
            self.totalBytes = totalBytesExpectedToWrite

            if totalBytesExpectedToWrite > 0 {
                self.progress = Double(totalBytesWritten) /
                                Double(totalBytesExpectedToWrite)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        Task { @MainActor in
            do {
                let destination = self.finalURL()

                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }

                try FileManager.default.moveItem(at: location, to: destination)

                self.destinationURL = destination
                self.progress = 1
                self.state = .completed(destination)
            } catch {
                self.state = .failed("保存文件失败：\(error.localizedDescription)")
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }

        Task { @MainActor in
            if (error as NSError).code == NSURLErrorCancelled {
                self.state = .idle
            } else {
                self.state = .failed(error.localizedDescription)
            }
        }
    }
}
