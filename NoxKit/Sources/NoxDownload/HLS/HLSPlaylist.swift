import Foundation
import CommonCrypto
import NoxCore


// MARK: - m3u8 清单

struct HLSPlaylist {
    struct Variant {
        let url: URL
        let bandwidth: Int
        let resolution: String?
    }

    struct Segment {
        let url: URL
        /// media sequence：未显式给出 IV 时，它就是 IV 的来源
        let sequence: Int
    }

    var isMaster = false
    var isLive = false
    var variants: [Variant] = []
    var segments: [Segment] = []
    var initSegmentURL: URL?
    var isEncrypted = false
    var keyMethod: String?
    var keyURL: URL?
    var keyIV: Data?
    var totalDuration: Double = 0

    static func parse(_ text: String, baseURL: URL) -> HLSPlaylist {
        var result = HLSPlaylist()
        let lines = text.components(separatedBy: .newlines)

        var pendingDuration: Double = 0
        var mediaSequence = 0
        var relativeIndex = 0
        var hasEndList = false
        var index = 0

        while index < lines.count {
            let raw = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1

            guard !raw.isEmpty else { continue }

            if raw.hasPrefix("#EXT-X-STREAM-INF:") {
                result.isMaster = true

                let info = String(raw.dropFirst("#EXT-X-STREAM-INF:".count))
                let bandwidth = attribute("BANDWIDTH", in: info).flatMap(Int.init) ?? 0
                let resolution = attribute("RESOLUTION", in: info)

                // URI 在紧随其后的第一条非注释行
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1

                    guard !candidate.isEmpty else { continue }
                    if candidate.hasPrefix("#") { continue }

                    if let url = URL(string: candidate, relativeTo: baseURL)?.absoluteURL {
                        result.variants.append(
                            Variant(url: url, bandwidth: bandwidth, resolution: resolution)
                        )
                    }
                    break
                }
                continue
            }

            if raw.hasPrefix("#EXT-X-KEY:") {
                let info = String(raw.dropFirst("#EXT-X-KEY:".count))
                let method = attribute("METHOD", in: info)?.uppercased() ?? "NONE"

                if method == "NONE" {
                    result.isEncrypted = false
                    result.keyMethod = nil
                    result.keyURL = nil
                    result.keyIV = nil
                } else {
                    result.isEncrypted = true
                    result.keyMethod = method

                    if let uri = attribute("URI", in: info),
                       let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL {
                        result.keyURL = url
                    }

                    result.keyIV = attribute("IV", in: info).flatMap(hexToData)
                }
                continue
            }

            if raw.hasPrefix("#EXT-X-MAP:") {
                let info = String(raw.dropFirst("#EXT-X-MAP:".count))

                if let uri = attribute("URI", in: info),
                   let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL {
                    result.initSegmentURL = url
                }
                continue
            }

            if raw.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                let value = String(raw.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count))
                mediaSequence = Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
                relativeIndex = 0
                continue
            }

            if raw.hasPrefix("#EXTINF:") {
                let value = String(raw.dropFirst("#EXTINF:".count))
                let number = value.split(separator: ",").first.map(String.init) ?? value
                pendingDuration = Double(number.trimmingCharacters(in: .whitespaces)) ?? 0
                continue
            }

            if raw.hasPrefix("#EXT-X-ENDLIST") {
                hasEndList = true
                continue
            }

            if raw.hasPrefix("#") { continue }

            // 真正的分片 URI
            if let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL {
                result.segments.append(Segment(url: url, sequence: mediaSequence + relativeIndex))
                relativeIndex += 1
                result.totalDuration += pendingDuration
                pendingDuration = 0
            }
        }

        if !result.isMaster {
            result.isLive = !hasEndList && !result.segments.isEmpty
        }

        return result
    }

    /// 解析 `KEY=VALUE`，忽略引号内的逗号（`CODECS="avc1,mp4a"` 这类值必需）
    static func attribute(_ name: String, in line: String) -> String? {
        var parts: [String] = []
        var current = ""
        var insideQuotes = false

        for character in line {
            if character == "\"" {
                insideQuotes.toggle()
                current.append(character)
                continue
            }

            if character == "," && !insideQuotes {
                parts.append(current)
                current = ""
                continue
            }

            current.append(character)
        }
        parts.append(current)

        let prefix = name + "="

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }

            return String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }

        return nil
    }

    static func hexToData(_ hex: String) -> Data? {
        var value = hex.lowercased()
        if value.hasPrefix("0x") { value = String(value.dropFirst(2)) }

        guard !value.isEmpty, value.count % 2 == 0 else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)

        var index = value.startIndex

        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }

            bytes.append(byte)
            index = next
        }

        return Data(bytes)
    }
}

// MARK: - AES-128-CBC（对应脚本 AES.decryptCBC）

