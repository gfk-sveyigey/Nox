import Foundation
import CommonCrypto
import NoxCore

enum HLSCrypto {
    enum Failure: LocalizedError {
        case badKeyLength(Int)
        case cryptFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .badKeyLength(let count):
                return String(format: L("HLS 密钥长度错误：%d"), count)
            case .cryptFailed(let status):
                return String(format: L("HLS 解密失败（%d）"), status)
            }
        }
    }

    /// AES-128-CBC + PKCS#7。HLS 的分片正是这个组合。
    static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw Failure.badKeyLength(key.count) }
        guard !data.isEmpty else { return data }

        var ivBytes = iv
        if ivBytes.count != kCCBlockSizeAES128 {
            ivBytes = Data(repeating: 0, count: kCCBlockSizeAES128)
        }

        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0

        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { inputBuffer in
                key.withUnsafeBytes { keyBuffer in
                    ivBytes.withUnsafeBytes { ivBuffer in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuffer.baseAddress, key.count,
                            ivBuffer.baseAddress,
                            inputBuffer.baseAddress, data.count,
                            outputBuffer.baseAddress, outputBuffer.count,
                            &moved
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { throw Failure.cryptFailed(status) }

        return output.prefix(moved)
    }

    /// 清单未显式给出 IV 时，用「分片序号」左补零成 16 字节大端。
    ///
    /// 注意：这里用的是 `EXT-X-MEDIA-SEQUENCE + 相对下标`，而不是数组下标 ——
    /// 带 `#EXT-X-MEDIA-SEQUENCE` 的流（直播、部分点播）两者不同，
    /// 用下标解出来的画面会花屏。
    static func defaultIV(sequence: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        let value = UInt64(truncatingIfNeeded: sequence).bigEndian

        withUnsafeBytes(of: value) { raw in
            for (offset, byte) in raw.enumerated() {
                bytes[8 + offset] = byte
            }
        }

        return Data(bytes)
    }
}

// MARK: - 下载器

enum HLSDownloaderError: LocalizedError {
    case liveStreamUnsupported
    case unsupportedEncryption(String)

    var errorDescription: String? {
        switch self {
        case .liveStreamUnsupported:
            return L("这是直播流（没有结束标记），无法合并为文件。")
        case .unsupportedEncryption(let method):
            return String(format: L("不支持的加密方式：%@"), method)
        }
    }
}

/// m3u8 → 分片并发下载 → AES-128 解密 → 顺序合并。
///
/// 三件事保证「取消」和「续传」都能工作：
/// 1. 全流程只靠 `Task.checkCancellation()` 与 URLSession 的 async API 响应取消，
///    调用方只要取消外层 `Task` 就能中止（不需要额外的 isCancelled 闭包）；
/// 2. 每个分片先写 `<name>.tmp` 再原子改名，因此「分片文件存在」等价于「该分片已完整下载」；
/// 3. 分片目录里存一份清单签名，签名变化（换清晰度、换集、密钥变化）就整体作废重来。
