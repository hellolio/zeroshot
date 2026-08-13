import Foundation
import AppKit
import FinderSync

/// FinderSync 扩展「陈旧实例」重载器。
///
/// macOS Sequoia/Tahoe 已知问题：app 重建/覆盖安装后，pkd 与 Finder 仍持有旧的扩展实例，
/// `FIFinderSyncController.isExtensionEnabled` 返回 true（设置页显示绿色），但 Finder
/// 不再对新实例调用 `menu(for:)`，右键菜单为空。手动去系统设置把扩展「关闭→打开」一次即
/// 恢复——其本质是切换 pluginkit 的 user election。主 app 非沙盒，可直接调用
/// /usr/bin/pluginkit 复现该操作：先 `-e ignore` 再 `-e use`，强制 pkd 完全停止并重启扩展。
enum FinderSyncReloader {
    static let pluginID = "com.zeroflow.app.finderSync"

    /// 节流间隔：避免短时间重复重载（例如每次应用启动时反复触发）。
    private static let throttleInterval: TimeInterval = 60
    private static var lastReload = Date.distantPast
    private static let queue = DispatchQueue(label: "com.zeroflow.app.finderSyncReloader")

    /// 扩展是否已启用（读取系统登记状态）。
    static var isExtensionEnabled: Bool {
        FIFinderSyncController.isExtensionEnabled
    }

    /// 异步执行一次「关闭→打开」重载。扩展未启用或处于节流期内时跳过。
    /// - Parameters:
    ///   - force: 为 true 时绕过节流限制。
    ///   - completion: 后台队列回调，`Bool` 表示本次是否实际执行了重载。
    static func reloadIfNeeded(force: Bool = false, completion: ((Bool) -> Void)? = nil) {
        let enabled = isExtensionEnabled
        queue.async {
            if !enabled {
                ZSLog("FinderSyncReloader: 扩展未启用,跳过重载")
                completion?(false)
                return
            }
            let now = Date()
            if !force && now.timeIntervalSince(lastReload) < throttleInterval {
                ZSLog("FinderSyncReloader: 节流跳过(距上次 \(Int(now.timeIntervalSince(lastReload)))s)")
                completion?(false)
                return
            }
            lastReload = now
            let ok = run()
            ZSLog("FinderSyncReloader: 重载完成 ok=\(ok)")
            completion?(ok)
        }
    }

    /// 同步执行 pluginkit election 循环（ignore → use）。返回是否全部成功。
    @discardableResult
    static func run() -> Bool {
        for argv in [["pluginkit", "-e", "ignore", "-i", pluginID],
                     ["pluginkit", "-e", "use", "-i", pluginID]] {
            guard runProcess(argv) else { return false }
            Thread.sleep(forTimeInterval: 0.8)
        }
        return true
    }

    private static func runProcess(_ argv: [String]) -> Bool {
        guard let executable = argv.first else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/\(executable)")
        process.arguments = Array(argv.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            ZSLog("FinderSyncReloader: 启动 pluginkit 失败 \(error)")
            return false
        }
    }
}
