import SwiftUI
import AppKit

/// 快捷键录制区（截图页使用）。
/// 通过注入 `Binding<ShortcutKey>` + `onSuspend/onResume` 闭包泛化：
/// 录制期间挂起/恢复 `GlobalHotkeyManager`，避免按同一组合触发截图。
/// （「切换」页的快捷键为固定两选一，不使用本组件。）
struct ShortcutRecorderView: View {
    @Binding var shortcut: ShortcutKey
    /// 录制期间临时挂起对应模块的全局热键（避免按同一组合触发自身）
    var onSuspend: () -> Void
    /// 录制结束（成功/取消/窗口关闭）后恢复
    var onResume: () -> Void
    /// 「恢复默认」按钮动作
    var resetToDefault: () -> Void
    @State private var isRecording = false
    @State private var errorMessage: String?
    @State private var eventMonitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isRecording ? Color.accentColor : Color(nsColor: .separatorColor),
                                          lineWidth: isRecording ? 1.5 : 1)
                    )
                Text(isRecording ? "按下新快捷键…" : shortcut.displayString)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isRecording ? Color.accentColor : (shortcut.isValid ? .primary : Color(nsColor: .secondaryLabelColor)))
                    .padding(.vertical, 5)
                    .padding(.horizontal, 12)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .frame(minWidth: 150)
            .fixedSize()
            .onTapGesture {
                toggleRecording()
            }

            Button("恢复默认") {
                resetToDefault()
                errorMessage = nil
            }
            .disabled(isRecording)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func toggleRecording() {
        isRecording.toggle()
        errorMessage = nil
        if isRecording {
            startListening()
        } else {
            stopRecording()
        }
    }

    private func startListening() {
        // 录制期间暂停对应模块的全局热键，避免按相同组合键触发其行为
        onSuspend()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            guard isRecording else { return event }
            if event.keyCode == 53 { // Esc 取消录制
                stopRecording()
                return nil
            }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let char = event.charactersIgnoringModifiers?.first.map(String.init) ?? ""
            capturePressed(keyCode: event.keyCode, character: char, modifiers: modifiers)
            return nil
        }
    }

    private func capturePressed(keyCode: UInt16, character: String, modifiers: NSEvent.ModifierFlags) {
        let newShortcut = ShortcutKey(character: character, keyCode: keyCode, modifiers: modifiers)
        if !newShortcut.isValid {
            errorMessage = "请至少按下一个修饰键（⌘/⌃/⌥/⇧）"
            return
        }
        shortcut = newShortcut
        errorMessage = nil
        stopRecording()
    }

    private func stopRecording() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        isRecording = false
        // 恢复对应模块的全局热键（录制中暂停了；此时 shortcut 已更新或保持原值，均以当前值重新注册）
        onResume()
    }
}
