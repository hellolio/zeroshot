import SwiftUI
import AppKit

struct ShortcutKey: Equatable {
    var character: String
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags

    static let standard = ShortcutKey(character: "s", keyCode: 1, modifiers: [.command, .shift])

    var isValid: Bool {
        !modifiers.isEmpty && !character.isEmpty
    }

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        if !character.isEmpty { parts.append(character.uppercased()) }
        return parts.joined()
    }

    var isDefault: Bool {
        character == "s" && keyCode == 1 && modifiers == [.command, .shift]
    }
}

extension ShortcutKey {
    /// 系统修饰键的 keyCode 集合，仅在捕获到真正的主键时才记为一次有效按键
    static let modifierKeyCodes: Set<UInt16> = [
        0x36, 0x37, 0x38, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F
    ]
}