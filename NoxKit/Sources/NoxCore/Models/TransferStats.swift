import Foundation

/// 下载过程中的实时统计（仅内存，不持久化）。
public struct TransferStats: Equatable {
    /// 已下载字节数
    public var bytesReceived: Int64 = 0
    /// 总字节数；0 表示服务器未返回总大小
    public var totalBytes: Int64 = 0
    /// 平滑后的瞬时速度（字节/秒）
    public var bytesPerSecond: Double = 0

    public init(bytesReceived: Int64 = 0, totalBytes: Int64 = 0, bytesPerSecond: Double = 0) {
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

    /// "12.4 MB / 58.7 MB"，总大小未知时只有已下载部分
    public var sizeText: String {
        let received = Self.formattedSize(bytesReceived)
        guard totalBytes > 0 else { return received }
        return "\(received) / \(Self.formattedSize(totalBytes))"
    }

    public var speedText: String {
        let value = max(bytesPerSecond, 0)

        let scaled: Double
        let unitKey: String

        if value >= 1_000_000_000 {
            scaled = value / 1_000_000_000
            unitKey = "GB"
        } else if value >= 1_000_000 {
            scaled = value / 1_000_000
            unitKey = "MB"
        } else if value >= 1_000 {
            scaled = value / 1_000
            unitKey = "KB"
        } else {
            scaled = value
            unitKey = "B"
        }

        let number = Self.decimal(scaled, maximumFractionDigits: scaled >= 100 ? 0 : 1)
        return String(format: L("%@ %@/s"), number, Self.unitLabel(unitKey))
    }

    public var displayText: String {
        "\(sizeText) · \(speedText)"
    }

    /// 供其它视图复用的大小格式化（例如「已下载 12.4 MB」）
    public static func formattedSize(_ bytes: Int64) -> String {
        let value = max(bytes, 0)

        let scaled: Double
        let unitKey: String

        if value >= 1_000_000_000 {
            scaled = Double(value) / 1_000_000_000
            unitKey = "GB"
        } else if value >= 1_000_000 {
            scaled = Double(value) / 1_000_000
            unitKey = "MB"
        } else if value >= 1_000 {
            scaled = Double(value) / 1_000
            unitKey = "KB"
        } else {
            scaled = Double(value)
            unitKey = "B"
        }

        let number = decimal(scaled, maximumFractionDigits: scaled >= 100 ? 0 : 1)
        return "\(number) \(unitLabel(unitKey))"
    }

    /// 按 App 语言格式化数字，保证小数点/千分位符合该语言习惯（fr 用 "1,5"）
    private static func decimal(_ value: Double, maximumFractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = AppLocale.current
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSNumber(value: value))
            ?? String(format: "%.\(maximumFractionDigits)f", value)
    }

    /// 用 switch 而不是动态拼 key，避免依赖不稳定的 API
    private static func unitLabel(_ key: String) -> String {
        switch key {
        case "GB": return L("GB")
        case "MB": return L("MB")
        case "KB": return L("KB")
        default: return L("B")
        }
    }
}
