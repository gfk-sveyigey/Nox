import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    private let qualities = ["Ask Every Time", "Best", "1080", "720", "480", "360"]
    @State private var showFolderPicker = false
    @State private var showFolderError = false
    @State private var folderError = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("下载") {
                    Picker("下载清晰度", selection: $appState.preferredQuality) {
                        ForEach(qualities, id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: appState.preferredQuality) { _, _ in appState.persist() }
                }

                Section("历史") {
                    Toggle("启动时清空历史", isOn: $appState.clearHistoryOnLaunch)
                        .onChange(of: appState.clearHistoryOnLaunch) { _, _ in appState.persist() }
                }

                Section("存储") {
                    Button {
                        showFolderPicker = true
                    } label: {
                        HStack {
                            Text("下载目录")
                            Spacer()
                            Text(appState.customDownloadFolderName ?? "App/Documents")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    if appState.customDownloadFolderName != nil {
                        Button("恢复为 App/Documents", role: .destructive) {
                            appState.clearDownloadFolder()
                        }
                    }
                }

                Section("关于") {
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    Text("VideoSaver")
                    Text("仅用于下载你有权访问和保存的内容。不会实现 DRM、付费墙或登录绕过。")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showFolderPicker) {
                FolderPicker { url in
                    do {
                        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                        appState.setDownloadFolder(bookmarkData: bookmark, displayName: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
                    } catch {
                        folderError = error.localizedDescription
                        showFolderError = true
                    }
                    showFolderPicker = false
                }
            }
            .alert("无法设置下载目录", isPresented: $showFolderError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(folderError)
            }
        }
    }
}

struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}
