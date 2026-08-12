import AppKit
import ApplicationServices

/// 私有单行桥：AX 窗口 → CGWindowID（AltTab 同款，需链接 ApplicationServices）
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ axUIElement: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

/// 窗口激活：还原最小化 → 激活 app → AX 置顶/设为 main。
/// 全部 AX 写操作放到专门的后台串行队列，绝不在事件 tap 回调里跑（与 Dock 模块同一原则）。
final class WindowActivator {
    static let shared = WindowActivator()

    private let axQueue = DispatchQueue(label: "zeroflow.window-activator", qos: .userInitiated)

    /// 异步聚焦窗口：先还原最小化，再 activate，再 AX 置顶。
    /// 本 app 的窗口走主线程直接操作 NSWindow —— AX 在本进程内会被 AppKit 转成
    /// `makeKeyAndOrderFront:`，后台线程调用会触发 AppKit 崩溃（SIGTRAP，见崩溃日志）。
    func focus(window: SwitcherWindow) {
        if window.pid == ProcessInfo.processInfo.processIdentifier {
            DispatchQueue.main.async { self.focusSelf(window) }
            return
        }
        axQueue.async {
            self.focusSync(window)
        }
    }

    /// 本 app 窗口：主线程 `makeKeyAndOrderFront`，完全不经过 AX。
    private func focusSelf(_ window: SwitcherWindow) {
        NSApp.activate(ignoringOtherApps: true)
        guard let nsWindow = NSApp.windows.first(where: { $0.windowNumber == Int(window.id) }) else {
            ZSLog("WindowActivator: own window wid=\(window.id) not found in NSApp.windows, activate only")
            return
        }
        if window.isMinimized {
            nsWindow.deminiaturize(nil)
        }
        nsWindow.makeKeyAndOrderFront(nil)
        ZSLog("WindowActivator: focused own window wid=\(window.id)")
    }

    private func focusSync(_ window: SwitcherWindow) {
        let app = window.app

        // 无窗口 app 占位卡：`app.activate` 对没有窗口的 app 通常无效（macOS 无窗口可激活）。
        // 对齐 AltTab：重新 launch 该 app（已运行会置前，多数 app 会尝试重开窗口）；失败退回 activate。
        if window.isWindowlessApp {
            if let bundleURL = app.bundleURL,
               (try? NSWorkspace.shared.launchApplication(at: bundleURL, configuration: [:])) != nil {
                ZSLog("WindowActivator: relaunched windowless app pid=\(window.pid)")
            } else {
                app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                ZSLog("WindowActivator: activated windowless app pid=\(window.pid) (launch failed)")
            }
            return
        }

        guard let axWindow = AXWindow.element(for: window.id, pid: window.pid, bounds: window.bounds) else {
            ZSLog("WindowActivator: no AX window matched wid=\(window.id), fallback to app activate")
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            return
        }

        // 1. 最小化窗口先还原（动画结束前不再重抓，避免迷你帧）
        if window.isMinimized {
            AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            ZSLog("WindowActivator: unminimized wid=\(window.id)")
        }

        // 2. 激活 app（macOS 14 起为建议性请求，需叠加 AX 步骤）
        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        // 3. AX 置顶 + 设为 main，跨 Space 时由系统自动切 Space
        AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        ZSLog("WindowActivator: raised wid=\(window.id) title='\(window.title)'")
    }
}