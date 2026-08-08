import SwiftUI
import AppKit
import ServiceManagement

/// 设置持久化存储。M0 只负责存取，不接入真实全局热键。
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Keys {
        static let shortcutKeyCode = "globalShortcut.keyCode"
        static let shortcutModifiers = "globalShortcut.modifiers"
        static let launchAtLogin = "launchAtLogin"
        static let saveDirectory = "saveDirectory"
        static let askSaveLocation = "askSaveLocation"
    }

    private let defaults: UserDefaults

    /// 默认保存位置：~/Downloads/zeroshot
    static var defaultSaveDirectory: String {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return (downloads ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("zeroshot", isDirectory: true).path
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.launchAtLogin: true,
            Keys.saveDirectory: Self.defaultSaveDirectory,
            Keys.askSaveLocation: false,
        ])
        ensureDefaultDirectoryExists()
    }

    // MARK: - 快捷键

    var shortcut: ShortcutKey {
        get {
            let keyCode = UInt16(defaults.integer(forKey: Keys.shortcutKeyCode))
            let modifiers = UInt(defaults.integer(forKey: Keys.shortcutModifiers))
            if keyCode == 0 && defaults.object(forKey: Keys.shortcutKeyCode) == nil {
                return .standard
            }
            var char = ShortcutKey.standard.character
            if let mapped = Self.character(forKeyCode: keyCode) {
                char = mapped
            }
            return ShortcutKey(character: char, keyCode: keyCode,
                               modifiers: NSEvent.ModifierFlags(rawValue: modifiers))
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Keys.shortcutKeyCode)
            defaults.set(Int(newValue.modifiers.rawValue), forKey: Keys.shortcutModifiers)
            NotificationCenter.default.post(
                name: GlobalHotkeyManager.didChangeNotification,
                object: nil,
                userInfo: ["shortcut": newValue]
            )
        }
    }

    /// 尝试把 macOS ANSI 键码映射为可显示字符
    static func character(forKeyCode code: UInt16) -> String? {
        let chars: [UInt16: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
            11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "5", 23: "6", 24: "7", 25: "8", 26: "9", 27: "0",
            36: "\r", 49: " ", 51: "⌫", 53: "esc", 55: "⌘", 48: "tab"
        ]
        return chars[code]
    }

    // MARK: - 启动

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Keys.launchAtLogin) }
        set {
            defaults.set(newValue, forKey: Keys.launchAtLogin)
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    defaults.set(!newValue, forKey: Keys.launchAtLogin)
                }
            }
        }
    }

    // MARK: - 保存

    var saveDirectory: String {
        get {
            let stored = defaults.string(forKey: Keys.saveDirectory)
                ?? Self.defaultSaveDirectory
            return stored
        }
        set {
            defaults.set(newValue, forKey: Keys.saveDirectory)
            ensureDefaultDirectoryExists()
        }
    }

    var askSaveLocation: Bool {
        get { defaults.bool(forKey: Keys.askSaveLocation) }
        set { defaults.set(newValue, forKey: Keys.askSaveLocation) }
    }

    // MARK: - 最近保存

    var lastSavedPath: String? {
        get { defaults.string(forKey: "lastSavedPath") }
        set { defaults.set(newValue, forKey: "lastSavedPath") }
    }

    /// 确保默认保存目录存在
    private func ensureDefaultDirectoryExists() {
        let dir = saveDirectory
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) {
            return
        }
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    func resetShortcutToDefault() {
        shortcut = .standard
    }
}