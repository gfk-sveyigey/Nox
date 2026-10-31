import Combine
import Foundation

/// 文件日志。
///
/// - 每条日志追加写入 `Application Support/Nox/Nox.log`；
/// - 「日志」页按块读取：进入时只加载**最近一块**（64 KB），滚到底点「加载更多」再往前读，
///   不会一次性把整份日志读进内存或列表；
/// - 可按天数保留（0 = 无限制），超期日志在写入与读取时都会被清理。
@MainActor
public final class LogStore: ObservableObject {
    public static let shared = LogStore()

    /// 「保留天数」可选项（0 = 无限制）
    public static let retentionOptions = [1, 3, 7, 30, 90, 0]
    /// 保留天数默认值
    public static let defaultRetentionDays = NoxDefaults.defaultLogRetentionDays
    private static let retentionKey = "Nox.logRetentionDays"

    /// 当前已加载的日志（按时间升序，最新在最后）
    @Published public private(set) var entries: [LogEntry] = []
    /// 是否还有更早的日志可以继续加载
    @Published public private(set) var canLoadMore = false

    /// 日志保留天数；0 = 无限制
    @Published public var retentionDays: Int {
        didSet {
            guard retentionDays != oldValue else { return }
            UserDefaults.standard.set(retentionDays, forKey: Self.retentionKey)
            pruneExpired()
            reload()
        }
    }

    /// 每次从文件尾部读取的字节数（分块加载，避免一次读入整份日志）
    private let pageBytes = 64 * 1024
    /// 当前已请求读取的字节数
    private var loadedBytes = 0
    /// 文件清理的节流时间戳
    private var lastFilePrune = Date.distantPast

    private let fileURL: URL
    private let dateFormatter: ISO8601DateFormatter

    private init() {
        let directory = DownloadStorage.rootDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("Nox.log")

        dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]

        let stored = UserDefaults.standard.object(forKey: Self.retentionKey) as? Int
        retentionDays = stored.flatMap { Self.retentionOptions.contains($0) ? $0 : nil }
            ?? Self.defaultRetentionDays

        loadedBytes = pageBytes
        pruneExpired()
        reload()
    }

    public func info(_ message: String) { log(.info, message) }
    public func warning(_ message: String) { log(.warning, message) }
    public func error(_ message: String) { log(.error, message) }

    public func log(_ level: LogLevel, _ message: String) {
        let entry = LogEntry(date: .now, level: level, message: message)
        entries.append(entry)
        appendToDisk(entry)
        pruneExpired()
    }

    /// 会话启动时记一条环境信息，方便排查问题。
    public func recordSessionStart() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        info("session start · Nox v\(version)(\(build)) · \(os)")
    }

    /// 载入下一块更早的日志。
    public func loadMore() {
        guard canLoadMore else { return }
        loadedBytes += pageBytes
        reload()
    }

    public func clear() {
        entries.removeAll()
        canLoadMore = false
        loadedBytes = pageBytes
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 导出为可分享的临时文本文件；失败返回 nil。
    public func exportFileURL() -> URL? {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("Nox-logs-\(Self.fileStamp()).txt")
        do {
            try exportText().write(to: target, atomically: true, encoding: .utf8)
            return target
        } catch {
            return nil
        }
    }

    /// 导出整份日志（显式导出时读取全文，避免日常加载占用内存）。
    public func exportText() -> String {
        if let text = try? String(contentsOf: fileURL, encoding: .utf8), !text.isEmpty {
            return text
        }
        return entries.map(line(for:)).joined(separator: "\n")
    }

    // MARK: - 读取

    private func reload() {
        let (text, truncated) = readTail(maxBytes: loadedBytes)
        canLoadMore = truncated

        entries = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap(Self.parse)
    }

    /// 从文件尾部往前读最多 `maxBytes`，返回文本与「是否还有更早内容」。
    private func readTail(maxBytes: Int) -> (String, Bool) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return ("", false) }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let truncated = size > UInt64(maxBytes)
        let start = truncated ? size - UInt64(maxBytes) : 0

        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()

        guard var text = String(data: data, encoding: .utf8) else {
            return ("", truncated)
        }

        // 从中间截断时，丢掉可能不完整的首行
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }

        return (text, truncated)
    }

    // MARK: - 写入与清理

    private func line(for entry: LogEntry) -> String {
        "\(dateFormatter.string(from: entry.date)) [\(entry.level.rawValue.uppercased())] \(entry.message)"
    }

    private func appendToDisk(_ entry: LogEntry) {
        guard let data = (line(for: entry) + "\n").data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// 删除超过保留天数的日志（内存 + 文件；0 表示不清理）。
    private func pruneExpired() {
        guard retentionDays != 0 else { return }

        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -retentionDays,
            to: .now
        ) ?? .distantPast

        entries.removeAll { $0.date < cutoff }

        // 文件清理较贵，节流到每分钟最多一次
        guard Date().timeIntervalSince(lastFilePrune) >= 60 else { return }
        lastFilePrune = .now
        pruneFile(before: cutoff)
    }

    private func pruneFile(before cutoff: Date) {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let kept = lines.filter { line in
            // 解析不了的行不确定日期，保守保留
            guard let entry = Self.parse(line) else { return true }
            return entry.date >= cutoff
        }

        guard kept.count != lines.count else { return }

        let out = kept.map(String.init).joined(separator: "\n") + "\n"
        try? out.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// 解析单行：ISO8601 时间戳 + [级别] + 正文。
    private static func parse(_ line: Substring) -> LogEntry? {
        guard let close = line.firstIndex(of: "]"),
              let open = line.firstIndex(of: "["),
              open < close else { return nil }

        let stamp = String(line[line.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        let levelRaw = String(line[line.index(after: open)..<close]).lowercased()
        let message = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        return LogEntry(
            date: formatter.date(from: stamp) ?? .distantPast,
            level: LogLevel(rawValue: levelRaw) ?? .info,
            message: message
        )
    }

    private static func fileStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }
}
