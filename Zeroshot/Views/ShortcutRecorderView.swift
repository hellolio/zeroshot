import SwiftUI
import AppKit

/// 快捷键录制区
struct ShortcutRecorderView: View {
    @ObservedObject var store: SettingsStore
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
                Text(isRecording ? "按下新快捷键…" : store.shortcut.displayString)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isRecording ? Color.accentColor : (store.shortcut.isValid ? .primary : Color(nsColor: .secondaryLabelColor)))
                    .padding(.vertical, 5)
                    .padding(.horizontal, 12)
            }
            .frame(minWidth: 150)
            .fixedSize()
            .onTapGesture {
                toggleRecording()
            }

            Button("恢复默认") {
                store.resetShortcutToDefault()
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
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            guard isRecording else { return event }
            if event.keyCode == 53 { // Esc 取消录制
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
        store.shortcut = newShortcut
        errorMessage = nil
        stopRecording()
    }

    private func stopRecording() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        isRecording = false
    }
}