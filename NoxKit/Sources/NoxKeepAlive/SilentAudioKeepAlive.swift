import AVFoundation
import Foundation
import NoxCore

/// 静音音频保活：`.playback` 会话 + 循环播放极低电平音频。
///
/// 注意：它会占用音频会话，可能打断其他 App 正在播放的音频，
/// 因此不是默认方案（默认走画中画）。
@MainActor
final class SilentAudioKeepAlive: KeepAliveStrategy {

    let name = L("静音音频")
    private(set) var isActive = false
    var onInterruption: (() -> Void)?

    private var player: AVAudioPlayer?
    private var observer: NSObjectProtocol?
    private var healthTask: Task<Void, Never>?

    /// 低频、极低电平的测试音，循环播放。
    ///
    /// 不用 0 字节 / 全零数据，也不把 player.volume 设为 0：系统可能把
    /// 「没有实际音频输出」的播放器当作未播放，锁屏一段时间后挂起 App。
    /// 1 LSB 的正弦波在听感上仍然是静音，但音频会话会持续处于播放状态。
    private static let silentData = silentWAV()
    private static let healthInterval: Duration = .seconds(5)

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])

        let player = try makePlayer()
        self.player = player
        isActive = true

        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
            Task { @MainActor in self?.onInterruption?() }
        }

        startHealthMonitor()
    }

    /// 播放器是否真的还在播（回前台时用来判断保活是否掉了）。
    var isLive: Bool { player?.isPlaying ?? false }

    func stop() {
        healthTask?.cancel()
        healthTask = nil
        player?.stop()
        player = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        isActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func makePlayer() throws -> AVAudioPlayer {
        let session = AVAudioSession.sharedInstance()
        try session.setActive(true)

        let player = try AVAudioPlayer(data: Self.silentData)
        player.numberOfLoops = -1
        player.volume = 1
        player.prepareToPlay()
        guard player.play() else {
            throw KeepAliveError.unavailable(name)
        }
        return player
    }

    /// 静音播放偶尔会被系统 / 路由变化停掉；只要 App 还有执行时间就重建播放器。
    private func startHealthMonitor() {
        healthTask?.cancel()
        healthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.healthInterval)
                guard let self, self.isActive, !Task.isCancelled else { return }
                guard self.player?.isPlaying != true else { continue }

                LogStore.shared.warning("silent audio stopped; restarting")
                do {
                    self.player?.stop()
                    self.player = try self.makePlayer()
                } catch {
                    self.isActive = false
                    LogStore.shared.warning(
                        "silent audio restart failed · \(error.localizedDescription)"
                    )
                    self.onInterruption?()
                    return
                }
            }
        }
    }

    /// 生成一段极低电平的 WAV，避免依赖资源文件。
    static func silentWAV(
        sampleRate: Int = 8000,
        duration: Double = 1.0,
        amplitude: Int16 = 1
    ) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let frames = max(Int(Double(sampleRate) * duration), 1)
        let dataSize = frames * channels * bitsPerSample / 8

        var data = Data()
        func appendASCII(_ value: String) { data.append(contentsOf: Array(value.utf8)) }
        func appendUInt32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func appendUInt16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        appendASCII("RIFF")
        appendUInt32(UInt32(36 + dataSize))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(byteRate))
        appendUInt16(UInt16(blockAlign))
        appendUInt16(UInt16(bitsPerSample))
        appendASCII("data")
        appendUInt32(UInt32(dataSize))

        // 440 Hz 正弦波，幅度 1 LSB；听感上仍是静音，但样本不是全 0。
        for frame in 0..<frames {
            let phase = 2.0 * Double.pi * 440.0 * Double(frame) / Double(sampleRate)
            let value = Int16((sin(phase) * Double(amplitude)).rounded())
            appendUInt16(UInt16(bitPattern: value))
        }

        return data
    }
}
