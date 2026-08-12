import SwiftUI
import AppKit

/// 设置页标签页
enum SettingsTab: String, CaseIterable {
    case general = "通用"
    case screenshot = "截图"
    case switcher = "切换"
    case dock = "Dock"
}

struct SettingsView: View {
    @StateObject private var store = SettingsStore.shared
    @State private var selectedTab: SettingsTab = .screenshot

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.bottom, 12)

            switch selectedTab {
            case .general:
                generalTab
            case .screenshot:
                screenshotTab
            case .switcher:
                switcherTab
            case .dock:
                dockTab
            }
        }
        .frame(minWidth: 520, minHeight: 560)
        .padding()
        // 无权限触发截图时自动跳到「截图」标签页，让权限引导直接可见
        .onReceive(NotificationCenter.default.publisher(for: .zeroflowOpenSettings)) { _ in
            selectedTab = .screenshot
        }
    }

    // MARK: - 截图

    private var screenshotTab: some View {
        Form {
            Section {
                Toggle("启用截图功能", isOn: $store.screenshotEnabled)
                    .onChange(of: store.screenshotEnabled) { enabled in
                        guard enabled else { return }
                        // 用便宜的 preflight 判断（不弹窗），未授权再弹系统授权窗，避免重复弹窗
                        if !ScreenRecordingPermission.isGranted {
                            ScreenRecordingPermission.requestAuthorization()
                        }
                    }
            } header: {
                Text("启用")
            } footer: {
                Text("关闭后，全局快捷键与菜单栏「立即截图」将停止工作。")
            }

            Section {
                LabeledContent("截屏快捷键") {
                    ShortcutRecorderView(
                        shortcut: $store.shortcut,
                        onSuspend: { GlobalHotkeyManager.shared.suspend() },
                        onResume: { GlobalHotkeyManager.shared.resume() },
                        resetToDefault: { store.resetShortcutToDefault() }
                    )
                }
            } header: {
                Text("快捷键")
            }

            if store.screenshotEnabled {
                Section {
                    ScreenRecordingPermissionRow()
                } header: {
                    Text("屏幕录制权限")
                }
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
    }

    // MARK: - 通用

    private var generalTab: some View {
        Form {
            Section {
                Toggle("开机自动启动（登录时打开）", isOn: $store.launchAtLogin)
            } header: {
                Text("开机自启")
            } footer: {
                Text("开启后，登录 macOS 时自动在后台启动 zeroflow，可随时用快捷键截图。")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 切换（⌘⇥ 窗口切换器）

    private var switcherTab: some View {
        Form {
            Section {
                Toggle("用 ⌘⇥ 显示窗口缩略图", isOn: $store.cmdTabSwitcherEnabled)
                    .onChange(of: store.cmdTabSwitcherEnabled) { enabled in
                        guard enabled else { return }
                        if !AccessibilityPermission.isGranted {
                            AccessibilityPermission.requestAuthorization()
                        }
                    }
            } header: {
                Text("启用")
            } footer: {
                Text("开启后，按下配置的组合键会弹出窗口缩略图切换器，可切换到最小化、同 app 多窗口、其他 Space 的窗口。关闭后完全恢复系统默认。")
            }

            if store.cmdTabSwitcherEnabled {
                Section {
                    Picker("切换快捷键", selection: $store.cmdTabShortcut) {
                        Text("⌘⇥").tag(ShortcutKey.cmdTabDefault)
                        Text("⌥`").tag(ShortcutKey.optionGraveDefault)
                    }
                    .pickerStyle(.radioGroup)
                } header: {
                    Text("快捷键")
                } footer: {
                    Text("选择其一弹出切换器：⌘⇥（Command + Tab）或 ⌥`（Option + Tab 上方的「`」键）。⇧ + 修饰键 + 主键 后退。")
                }

                Section {
                    AccessibilityPermissionRow(message: "需要「辅助功能」权限才能接管 ⌘⇥ 切换")
                    Text("该权限与 Dock 单击最小化共用，若已开启则此处直接显示绿色。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text("权限")
                }

                Section {
                    Toggle("显示其他 Space 的窗口", isOn: $store.windowSwitcherAllSpaces)
                    Toggle("显示无窗口的应用", isOn: $store.windowSwitcherShowWindowlessApps)
                } header: {
                    Text("选项")
                } footer: {
                    Text("关闭「显示其他 Space 的窗口」后只显示当前 Space 的窗口。开启「显示无窗口的应用」后，窗口全部关闭但仍在运行的应用也会显示（无缩略图时显示 app 图标）。")
                }

                Section {
                    ScreenRecordingPermissionRow()
                } header: {
                    Text("屏幕录制权限")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Dock

    private var dockTab: some View {
        Form {
            Section {
                Toggle("单击 Dock 图标最小化窗口", isOn: $store.dockClickMinimize)
                    .onChange(of: store.dockClickMinimize) { enabled in
                        guard enabled else { return }
                        if !AccessibilityPermission.isGranted {
                            AccessibilityPermission.requestAuthorization()
                        }
                    }
                if store.dockClickMinimize {
                    AccessibilityPermissionRow(message: "需要「辅助功能」权限才能最小化窗口")
                    LabeledContent("桌面与 Dock") {
                        Button("前往设置") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
                        }
                    }
                    Text("建议同时开启「桌面与 Dock → 最小化窗口到应用图标」，可避免最小化后还原位置丢失。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Dock")
            }
        }
        .formStyle(.grouped)
    }
}

/// 截图模块的屏幕录制权限状态与引导（与 AccessibilityPermissionRow 样式一致）
private struct ScreenRecordingPermissionRow: View {
    @State private var granted = ScreenRecordingPermission.isGranted

    var body: some View {
        Group {
            if granted {
                Label("屏幕录制权限已开启", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("需要「屏幕录制」权限才能截图", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("1. 点击下方「打开系统设置授权」\n2. 在「隐私与安全性 → 屏幕录制」中为 Zeroflow 打开开关\n3. 授权后回到应用，点击「重新检测」")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 12) {
                        Button("打开系统设置授权") {
                            ScreenRecordingPermission.requestAuthorization()
                        }
                        Button("重新检测") {
                            recheck()
                        }
                    }
                }
            }
        }
        // 首次出现 + 授权后回到应用自动重查（真实探测，避免 preflight 缓存误判）
        .onAppear {
            recheck()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recheck()
        }
    }

    private func recheck() {
        Task { @MainActor in
            granted = await ScreenRecordingPermission.hasScreenCaptureAccess()
        }
    }
}

#Preview {
    SettingsView()
}
