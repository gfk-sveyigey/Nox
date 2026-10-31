import Foundation



/// 下载速度估算器。
///
/// 重新设计的原因：旧的实现直接用「上一帧字节数 + 时间差」算瞬时速度，再与旧值做
/// 指数平滑，在下面两种情况下必然给出错误数字：
/// 1. 切回前台：后台期间进度定时器不触发，恢复后的第一帧要么把「跨越整个后台的
///    时间差」当分母，要么（重置基准时）把后台累积的字节塞进 1 秒里，于是速度
///    不是掉到 0 就是虚高一大截；
/// 2. 重新开始任务：字节计数从头累积，沿用上一段的采样会算出负数或残留旧速度。
///
/// 这里的做法只依赖两个输入：**累计字节数** 与 **单调时钟时间戳**：
/// - 在滑动窗口（默认 6 秒）内取首尾样本差分，天生平滑，不依赖逐帧瞬时值；
/// - 相邻样本间隔超过 `gapThreshold` 时判定为「时间断层」，清空窗口重新取样，
///   绝不把断层时长算进分母 —— 这是切回前台不再乱跳的关键；
/// - 累计字节回退时（重新开始任务）自动重置；
/// - 没有新字节时窗口差值归零，速度自然回落到 0，不需要额外衰减逻辑。
struct SpeedMeter {

    private struct Sample {
        let bytes: Int64
        let time: TimeInterval
    }

    /// 参与平均的时间窗口长度（秒）。
    var window: TimeInterval = 6
    /// 相邻样本间隔超过它即视为时间断层。
    var gapThreshold: TimeInterval = 3
    /// 窗口内最多保留的样本数，防止高频喂入时无限增长。
    var sampleLimit = 32

    private(set) var bytesPerSecond: Double = 0
    private var samples: [Sample] = []
    private var lastBytes: Int64?

    init() {}

    /// 单调时钟，不受系统时间调整影响。
    static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// 清空采样。切后台、重新开始任务时调用，避免沿用旧速度。
    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        lastBytes = nil
        bytesPerSecond = 0
    }

    /// 喂入一个「累计字节数」样本，返回平滑后的速度（字节/秒）。
    @discardableResult
    mutating func update(totalBytes: Int64, at time: TimeInterval) -> Double {
        if let last = lastBytes, totalBytes < last {
            // 计数器回退：任务被重新开始，重新采样。
            reset()
        }
        lastBytes = totalBytes

        if let lastSample = samples.last, time - lastSample.time > gapThreshold {
            // 时间断层：丢弃旧窗口重新开始，避免用挂起的时长当分母。
            samples.removeAll(keepingCapacity: true)
        }

        samples.append(Sample(bytes: totalBytes, time: time))

        while let first = samples.first, time - first.time > window {
            samples.removeFirst()
        }
        while samples.count > sampleLimit {
            samples.removeFirst()
        }

        guard samples.count > 1, let first = samples.first, let last = samples.last else {
            bytesPerSecond = 0
            return bytesPerSecond
        }

        let interval = last.time - first.time
        let delta = last.bytes - first.bytes
        guard interval > 0.2, delta > 0 else {
            bytesPerSecond = 0
            return bytesPerSecond
        }

        bytesPerSecond = Double(delta) / interval
        return bytesPerSecond
    }
}
