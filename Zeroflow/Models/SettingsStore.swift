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
        static let screenshotEnabled = "screenshotEnabled"
        static let dockClickMinimize = "dockClickMinimize"
        static let cmdTabSwitcherEnabled = "cmdTabSwitcherEnabled"
        static let windowSwitcherAllSpaces = "windowSwitcherAllSpaces"
        static let windowSwitcherShowWindowlessApps = "windowSwitcherShowWindowlessApps"
        static let cmdTabShortcutKeyCode = "cmdTabShortcut.keyCode"
        static let cmdTabShortcutModifiers = "cmdTabShortcut.modifiers"
    }

    private let defaults: UserDefaults

    /// 默认保存位置：~/Downloads/zeroflow
    static var defaultSaveDirectory: String {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return (downloads ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("zeroflow", isDirectory: true).path
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.launchAtLogin: true,
            Keys.saveDirectory: Self.defaultSaveDirectory,
            Keys.askSaveLocation: false,
            Keys.screenshotEnabled: false,
            Keys.dockClickMinimize: false,
            Keys.cmdTabSwitcherEnabled: false,
            Keys.windowSwitcherAllSpaces: true,
            Keys.windowSwitcherShowWindowlessApps: true,
            Keys.cmdTabShortcutKeyCode: Int(ShortcutKey.cmdTabDefault.keyCode),
            Keys.cmdTabShortcutModifiers: Int(ShortcutKey.cmdTabDefault.modifiers.rawValue),
        ])
        _launchAtLogin = Published(initialValue: defaults.bool(forKey: Keys.launchAtLogin))
        _saveDirectory = Published(initialValue: defaults.string(forKey: Keys.saveDirectory) ?? Self.defaultSaveDirectory)
        _askSaveLocation = Published(initialValue: defaults.bool(forKey: Keys.askSaveLocation))
        _screenshotEnabled = Published(initialValue: defaults.bool(forKey: Keys.screenshotEnabled))
        _dockClickMinimize = Published(initialValue: defaults.bool(forKey: Keys.dockClickMinimize))
        _cmdTabSwitcherEnabled = Published(initialValue: defaults.bool(forKey: Keys.cmdTabSwitcherEnabled))
        _windowSwitcherAllSpaces = Published(initialValue: defaults.bool(forKey: Keys.windowSwitcherAllSpaces))
        _windowSwitcherShowWindowlessApps = Published(initialValue: defaults.bool(forKey: Keys.windowSwitcherShowWindowlessApps))
        _shortcut = Published(initialValue: Self.loadShortcut(from: defaults))
        _cmdTabShortcut = Published(initialValue: Self.loadCmdTabShortcut(from: defaults))
        ensureDefaultDirectoryExists()
    }

    // MARK: - 快捷键

    @Published var shortcut: ShortcutKey {
        didSet {
            defaults.set(Int(shortcut.keyCode), forKey: Keys.shortcutKeyCode)
            defaults.set(Int(shortcut.modifiers.rawValue), forKey: Keys.shortcutModifiers)
            NotificationCenter.default.post(
                name: GlobalHotkeyManager.didChangeNotification,
                object: nil,
                userInfo: ["shortcut": shortcut]
            )
        }
    }

    private static func loadShortcut(from defaults: UserDefaults) -> ShortcutKey {
        loadShortcut(from: defaults,
                     keyCodeKey: Keys.shortcutKeyCode,
                     modifiersKey: Keys.shortcutModifiers,
                     defaultKeyCode: ShortcutKey.standard.keyCode,
                     defaultModifiers: UInt(ShortcutKey.standard.modifiers.rawValue),
                     defaultCharacter: ShortcutKey.standard.character)
    }

    private static func loadCmdTabShortcut(from defaults: UserDefaults) -> ShortcutKey {
        let loaded = loadShortcut(from: defaults,
                                  keyCodeKey: Keys.cmdTabShortcutKeyCode,
                                  modifiersKey: Keys.cmdTabShortcutModifiers,
                                  defaultKeyCode: ShortcutKey.cmdTabDefault.keyCode,
                                  defaultModifiers: UInt(ShortcutKey.cmdTabDefault.modifiers.rawValue),
                                  defaultCharacter: ShortcutKey.cmdTabDefault.character)
        // 切换器快捷键固定两选一（⌘⇥ / ⌥`）；旧的自由录制值钳回默认
        switch loaded.keyCode {
        case ShortcutKey.cmdTabDefault.keyCode: return .cmdTabDefault
        case ShortcutKey.optionGraveDefault.keyCode: return .optionGraveDefault
        default: return .cmdTabDefault
        }
    }

    private static func loadShortcut(from defaults: UserDefaults,
                                     keyCodeKey: String,
                                     modifiersKey: String,
                                     defaultKeyCode: UInt16,
                                     defaultModifiers: UInt,
                                     defaultCharacter: String) -> ShortcutKey {
        let keyCode = UInt16(defaults.integer(forKey: keyCodeKey))
        let modifiers = UInt(defaults.integer(forKey: modifiersKey))
        if keyCode == 0 && defaults.object(forKey: keyCodeKey) == nil {
            return ShortcutKey(character: defaultCharacter, keyCode: defaultKeyCode,
                               modifiers: NSEvent.ModifierFlags(rawValue: defaultModifiers))
        }
        var char = defaultCharacter
        if let mapped = character(forKeyCode: keyCode) {
            char = mapped
        }
        return ShortcutKey(character: char, keyCode: keyCode,
                           modifiers: NSEvent.ModifierFlags(rawValue: modifiers))
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

    /// 防止注册失败回滚时的重入循环
    private var isSyncingLaunchAtLogin = false

    @Published var launchAtLogin: Bool {
        didSet {
            syncLaunchAtLogin()
        }
    }

    /// 启动时把「持久化的开关值」与「系统登录项实际注册状态」对齐。
    /// 首次启动默认值为开（init 直接读入，didSet 不触发），此方法补上真正注册，
    /// 修复「默认开但重启不自动启动」的问题。
    func reconcileLaunchAtLogin() {
        syncLaunchAtLogin()
    }

    /// 将当前 launchAtLogin 值同步到系统登录项（注册/注销）。
    /// 手动开关与启动时 reconcile 共用，带防重入守卫。
    private func syncLaunchAtLogin() {
        guard !isSyncingLaunchAtLogin else { return }
        isSyncingLaunchAtLogin = true
        defer { isSyncingLaunchAtLogin = false }

        defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
        guard #available(macOS 13.0, *) else { return }

        let status = SMAppService.mainApp.status
        if launchAtLogin {
            guard status != .enabled else {
                ZSLog("launchAtLogin ON: already registered, skip")
                return
            }
            do {
                try SMAppService.mainApp.register()
                ZSLog("launchAtLogin ON: registered, status=\(status)")
            } catch {
                let reverted = false
                launchAtLogin = reverted
                defaults.set(false, forKey: Keys.launchAtLogin)
                ZSLog("launchAtLogin ON failed: \(error), status=\(status)")
            }
        } else {
            switch status {
            case .notRegistered, .notFound:
                ZSLog("launchAtLogin OFF: not registered, only persist OFF, status=\(status)")
            default:
                do {
                    try SMAppService.mainApp.unregister()
                    ZSLog("launchAtLogin OFF: unregistered, status=\(status)")
                } catch {
                    let reverted = true
                    launchAtLogin = reverted
                    defaults.set(true, forKey: Keys.launchAtLogin)
                    ZSLog("launchAtLogin OFF failed: \(error), status=\(status)")
                }
            }
        }
    }

    // MARK: - 保存

    @Published var saveDirectory: String {
        didSet {
            defaults.set(saveDirectory, forKey: Keys.saveDirectory)
            ensureDefaultDirectoryExists()
        }
    }

    @Published var askSaveLocation: Bool {
        didSet { defaults.set(askSaveLocation, forKey: Keys.askSaveLocation) }
    }

    // MARK: - 截图

    @Published var screenshotEnabled: Bool {
        didSet {
            defaults.set(screenshotEnabled, forKey: Keys.screenshotEnabled)
            NotificationCenter.default.post(
                name: GlobalHotkeyManager.screenshotEnabledDidChangeNotification,
                object: nil,
                userInfo: ["enabled": screenshotEnabled]
            )
        }
    }

    // MARK: - Dock

    @Published var dockClickMinimize: Bool {
        didSet {
            defaults.set(dockClickMinimize, forKey: Keys.dockClickMinimize)
            NotificationCenter.default.post(
                name: DockClickMinimizer.didChangeNotification,
                object: nil,
                userInfo: ["enabled": dockClickMinimize]
            )
        }
    }

    // MARK: - 窗口切换器

    @Published var cmdTabSwitcherEnabled: Bool {
        didSet {
            defaults.set(cmdTabSwitcherEnabled, forKey: Keys.cmdTabSwitcherEnabled)
            NotificationCenter.default.post(
                name: CommandTabSwitcher.didChangeNotification,
                object: nil,
                userInfo: ["enabled": cmdTabSwitcherEnabled]
            )
        }
    }

    @Published var windowSwitcherAllSpaces: Bool {
        didSet {
            defaults.set(windowSwitcherAllSpaces, forKey: Keys.windowSwitcherAllSpaces)
        }
    }

    @Published var windowSwitcherShowWindowlessApps: Bool {
        didSet {
            defaults.set(windowSwitcherShowWindowlessApps, forKey: Keys.windowSwitcherShowWindowlessApps)
        }
    }

    @Published var cmdTabShortcut: ShortcutKey {
        didSet {
            defaults.set(Int(cmdTabShortcut.keyCode), forKey: Keys.cmdTabShortcutKeyCode)
            defaults.set(Int(cmdTabShortcut.modifiers.rawValue), forKey: Keys.cmdTabShortcutModifiers)
            NotificationCenter.default.post(
                name: CommandTabSwitcher.shortcutDidChangeNotification,
                object: nil,
                userInfo: ["shortcut": cmdTabShortcut]
            )
        }
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