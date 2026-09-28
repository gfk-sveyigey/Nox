import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var parser = VideoParser()
    @StateObject private var downloader = DownloadManager()

    @State private var pageURL = ""
    @State private var variants: [VideoVariant] = []
    @State private var selectedVariant: VideoVariant?
    @State private var pageTitle = "video"
    @State private var isParsing = false
    @State private var message = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("视频页面") {
                    TextField(
                        "粘贴视频页面 URL",
                        text: $pageURL,
                        axis: .vertical
                    )
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()

                    Button {
                        parse()
                    } label: {
                        if isParsing {
                            ProgressView()
                        } else {
                            Label("解析视频", systemImage: "magnifyingglass")
                        }
                    }
                    .disabled(isParsing || pageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !variants.isEmpty {
                    Section("可用版本") {
                        ForEach(variants) { variant in
                            Button {
                                selectedVariant = variant
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(variant.quality) \(variant.format.uppercased())")
                                            .foregroundStyle(.primary)

                                        Text(variant.url.absoluteString)
                                            .font(.caption2)
                                            .lineLimit(1)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if selectedVariant == variant {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }

                    Section {
                        Button {
                            startDownload()
                        } label: {
                            Label("下载所选版本", systemImage: "arrow.down.circle.fill")
                        }
                        .disabled(selectedVariant == nil || downloader.state == .downloading)
                    }
                }

                if downloader.state == .downloading {
                    Section("下载进度") {
                        ProgressView(value: downloader.progress)

                        HStack {
                            Text(ByteFormatter.string(downloader.downloadedBytes))
                            Spacer()
                            if downloader.totalBytes > 0 {
                                Text(ByteFormatter.string(downloader.totalBytes))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Button("取消下载", role: .destructive) {
                            downloader.cancel()
                        }
                    }
                }

                if case .completed(let url) = downloader.state {
                    Section("下载完成") {
                        Text(url.lastPathComponent)
                            .font(.subheadline)

                        ShareLink(
                            item: url,
                            preview: SharePreview(url.lastPathComponent)
                        ) {
                            Label("分享 / 保存到“文件”", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                if !message.isEmpty {
                    Section("状态") {
                        Text(message)
                    }
                }
            }
            .navigationTitle("Video Saver")
        }
    }

    private func parse() {
        guard let url = URL(string: pageURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            message = "URL 无效"
            return
        }

        isParsing = true
        message = ""
        variants = []
        selectedVariant = nil

        Task {
            do {
                let result = try await parser.parse(pageURL: url)

                variants = result.sorted {
                    qualityNumber($0.quality) > qualityNumber($1.quality)
                }

                if let first = variants.first {
                    selectedVariant = first
                }

                message = "找到 \(variants.count) 个视频版本"
            } catch {
                message = error.localizedDescription
            }

            isParsing = false
        }
    }

    private func startDownload() {
        guard let variant = selectedVariant,
              let page = URL(string: pageURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return
        }

        downloader.start(
            url: variant.url,
            fileName: pageTitle,
            referer: page
        )
    }

    private func qualityNumber(_ value: String) -> Int {
        let digits = value.filter(\.isNumber)
        return Int(digits) ?? 0
    }
}

enum ByteFormatter {
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

#Preview {
    ContentView()
}
