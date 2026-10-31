import Foundation

public struct LogEntry: Identifiable, Equatable {
    public let id = UUID()
    public let date: Date
    public let level: LogLevel
    public let message: String

    init(date: Date, level: LogLevel, message: String) {
        self.date = date
        self.level = level
        self.message = message
    }
}
