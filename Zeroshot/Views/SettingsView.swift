import SwiftUI

struct SettingsView: View {
    @StateObject private var store = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("截屏快捷键") {
                    ShortcutRecorderView(store: store)
                }
                Toggle("开机自动启动（登录时打开）", isOn: $store.launchAtLogin)
            } header: {
                Text("快捷键与启动")
            }

            Section {
                LabeledContent("默认保存位置") {
                    SaveDirectoryRow(store: store)
                }
                Toggle("保存时询问位置", isOn: $store.askSaveLocation)
            } header: {
                Text("保存")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 420)
        .padding()
    }
}

#Preview {
    SettingsView()
}