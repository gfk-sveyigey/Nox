import Combine
import Foundation
import UIKit
import WebKit
import NoxCore
import NoxKeepAlive

// MARK: - 文件名

extension DownloadManager {
    // MARK: - 文件名

    /// m3u8 合并后是 MP4 容器；其余按上报的格式
    static func fileExtension(for format: String) -> String {
        let lowered = format.lowercased()
        if lowered.isEmpty || lowered == "m3u8" { return "mp4" }
        return lowered
    }

    /// 避开 Documents 里已存在的同名文件（追加 " (2)"、" (3)"…），
    /// 否则会静默覆盖用户已有的视频。
    static func uniqueFilename(_ proposed: String) -> String {
        let directory = DownloadStorage.documentsDirectory
        let base = safeFilename(proposed)

        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(base).path
        ) else {
            return base
        }

        let url = URL(fileURLWithPath: base)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        for index in 2...999 {
            let candidate = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"

            if !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(candidate).path
            ) {
                return candidate
            }
        }

        return base
    }

    static func safeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")

        let cleaned = name
            .components(separatedBy: invalid)
            .joined(separator: "_")

        let value = String(cleaned.prefix(180))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return value.isEmpty ? "video.mp4" : value
    }
}
