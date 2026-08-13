import FinderSync
import AppKit
import Foundation
import os.log

private let finderSyncLog = OSLog(subsystem: "com.zeroflow.app.finderSync", category: "FinderSync")

/// 主 app 与 FinderSync 扩展跨进程共享的设置。
/// 扩展为沙盒进程、主 app 为非沙盒进程,两者都带 8NHN73Q43T.com.zeroflow.app App Group
/// 授权。不用 UserDefaults(suiteName:) 读 App Group(沙盒扩展里读不到,cfprefsd 报
/// Container: (null)),而是双方直接读写 group container 里同一份 plist 文件。
enum FinderSyncSharedDefaults {
    static let suiteName = "8NHN73Q43T.com.zeroflow.app"
    static let settingsFileName = "finder-sync-settings.plist"
    static let enabledKey = "finderNewFileEnabled"
    static let fileNameKey = "finderNewFileName"
    static let appLanguageKey = "appLanguage"

    static let defaultFileName = "new file.md"

    /// 真实用户主目录。注意:沙盒进程里 FileManager.default.homeDirectoryForCurrentUser
    /// 返回的是容器目录(~/Library/Containers/.../Data),不是 /Users/用户名,直接用于
    /// directoryURLs 会导致 Finder 完全不监控任何用户路径。这里用 NSUserName() 拼出真实路径。
    static var userHome: URL {
        URL(fileURLWithPath: "/Users/\(NSUserName())", isDirectory: true)
    }

    private static var settingsURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: suiteName)?
            .appendingPathComponent(settingsFileName)
    }

    private static func settings() -> [String: Any] {
        guard let url = settingsURL,
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else { return [:] }
        return dict
    }

    /// 每次构建菜单前重读文件,保证主 app 的开关切换即时生效
    static func isEnabled() -> Bool {
        (settings()[enabledKey] as? Bool) ?? false
    }

    static func fileName() -> String {
        let raw = settings()[fileNameKey] as? String ?? defaultFileName
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultFileName : trimmed
    }

    /// 与 L10n.AppLanguage 对齐的语言解析（system 时跟随系统首选语言）
    static func effectiveLanguage() -> String {
        let raw = settings()[appLanguageKey] as? String ?? "system"
        if raw != "system" && !raw.isEmpty { return raw }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
        if preferred.hasPrefix("zh") { return "zh-Hans" }
        if preferred.hasPrefix("ja") { return "ja" }
        return "en"
    }
}

extension Notification.Name {
    /// 主 app 改变「访达新建文件」设置时通知扩展增删 directoryURLs
    static let zeroflowFinderNewFileDidChange = Notification.Name("zeroflow.finderNewFileDidChange")
}

/// Finder 右键菜单注入「新建空文件」。
final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        updateDirectoryURLs()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: .zeroflowFinderNewFileDidChange,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    private func updateDirectoryURLs() {
        // 仅用户目录（含桌面），满足绝大多数右键场景且避免整盘监控拖慢访达；
        // 关闭时清空，Finder 完全不监控，零开销。
        let on = FinderSyncSharedDefaults.isEnabled()
        let urls: Set<URL> = on ? [FinderSyncSharedDefaults.userHome] : []
        os_log("updateDirectoryURLs enabled=%{public}@ dirs=%{public}@",
               log: finderSyncLog, type: .info, String(on), String(describing: urls))
        FIFinderSyncController.default().directoryURLs = urls
    }

    @objc private func settingsDidChange(_ note: Notification) {
        updateDirectoryURLs()
    }

    // MARK: - 菜单

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        os_log("menu(for:) called, enabled=%{public}@ kind=%d",
               log: finderSyncLog, type: .info, String(FinderSyncSharedDefaults.isEnabled()), menuKind.rawValue)
        guard FinderSyncSharedDefaults.isEnabled() else { return nil }
        guard let directory = targetDirectory() else {
            os_log("menu(for:) targetDirectory() == nil, targeted=%{public}@ selected=%{public}@",
                   log: finderSyncLog, type: .error,
                   String(describing: FIFinderSyncController.default().targetedURL()),
                   String(describing: FIFinderSyncController.default().selectedItemURLs()))
            return nil
        }

        let item = NSMenuItem(
            title: FinderSyncMenuStrings.newFileTitle,
            action: #selector(createFile(_:)),
            keyEquivalent: ""
        )
        item.target = self

        let menu = NSMenu(title: "")
        menu.addItem(item)
        return menu
    }

    /// 确定创建文件的目标目录：
    /// - 右键容器（窗口/桌面空白）→ targetedURL 即该目录
    /// - 右键文件夹 → 在其内创建
    /// - 右键普通文件 → 在其父目录创建
    private func targetDirectory() -> URL? {
        let controller = FIFinderSyncController.default()
        for url in [controller.targetedURL(), controller.selectedItemURLs()?.first].compactMap({ $0 }) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? url : url.deletingLastPathComponent()
            }
        }
        return nil
    }

    // MARK: - 创建

    @objc private func createFile(_ sender: Any?) {
        // Finder 通过 XPC 序列化菜单项时不会保留 NSMenuItem 的 representedObject，
        // 因此不能依赖 sender 携带目录；右键目标此刻仍有效，直接重新推导。
        guard let directory = targetDirectory() else {
            os_log("createFile: targetDirectory() == nil", log: finderSyncLog, type: .error)
            return
        }
        guard let url = NewFileMaker.create(in: directory, baseName: FinderSyncSharedDefaults.fileName()) else {
            os_log("createFile: FAILED in %@", log: finderSyncLog, type: .error, directory.path)
            NSLog("FinderSync: 创建文件失败 in %@", directory.path)
            return
        }
        os_log("createFile: OK -> %@", log: finderSyncLog, type: .info, url.path)
        // 创建后在访达中选中新文件
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// 右键菜单文案，按共享语言设置取词
enum FinderSyncMenuStrings {
    static var newFileTitle: String {
        switch FinderSyncSharedDefaults.effectiveLanguage() {
        case "zh-Hans": return "新建空文件"
        case "ja": return "空の新規ファイル"
        default: return "New Empty File"
        }
    }
}

enum NewFileMaker {
    /// 在指定目录创建空文件，文件名按「基础名 序号.扩展名」去重
    static func create(in directory: URL, baseName: String) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        guard let url = uniqueURL(in: directory, baseName: baseName) else { return nil }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
        return url
    }

    private static func uniqueURL(in directory: URL, baseName: String) -> URL? {
        let sanitized = baseName.replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: ":", with: "")
        guard !sanitized.isEmpty else { return nil }

        let nsName = sanitized as NSString
        let ext = nsName.pathExtension
        let stem = ext.isEmpty ? sanitized : String(nsName.deletingPathExtension)

        let fileManager = FileManager.default
        var candidate = directory.appendingPathComponent(sanitized)
        var index = 1
        while fileManager.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            candidate = directory.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }
}