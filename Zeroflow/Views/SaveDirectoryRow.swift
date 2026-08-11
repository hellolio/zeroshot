import SwiftUI
import AppKit

/// 保存位置行：路径显示 + 选择 + 打开
struct SaveDirectoryRow: View {
    @ObservedObject var store: SettingsStore
    @State private var toastMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.saveDirectory)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            HStack {
                Button("选择…") {
                    chooseDirectory()
                }
                Button("打开") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: store.saveDirectory)
                }

                if let toastMessage {
                    Text(toastMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.directoryURL = URL(fileURLWithPath: store.saveDirectory)
        panel.begin { response in
            if response == .OK, let url = panel.url {
                let newPath = url.path
                do {
                    try FileManager.default.createDirectory(
                        at: url, withIntermediateDirectories: true, attributes: nil
                    )
                    store.saveDirectory = newPath
                    toastMessage = nil
                } catch {
                    toastMessage = "目录创建失败，请重试"
                }
            }
        }
    }
}