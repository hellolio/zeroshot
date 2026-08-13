import AppKit
import ApplicationServices

/// 窗口级最近激活时间（MRU），对齐 AltTab 的 per-window `lastActivityTime`。
/// 对每个运行中的 app 监听 `kAXFocusedWindowChangedNotification`，聚焦窗口变化时用
/// `_AXUIElementGetWindow`（WindowActivator 里已声明的私有桥）取 CGWindowID 并打时间戳。
/// app 启动/退出时增删观察者；返回辅助功能授权后（didBecomeActive）补建。
final class WindowActivityTracker {
    static let shared = WindowActivityTracker()

    private let lock = NSLock()
    private var activity: [CGWindowID: Date] = [:]
    private var observers: [NSObjectProtocol] = []
    private var axObservers: [pid_t: AXObserver] = [:]

    private init() {
        observeLifecycle()
        if AccessibilityPermission.isGranted {
            rebuildObservers()
        }
    }

    // MARK: - 对外查询

    func lastActiveDate(for wid: CGWindowID) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return activity[wid]
    }

    /// 记录窗口最近激活时间（MRU）。AX 焦点通知是异步的，快速连按 ⌘⇥ 时可能尚未落库，
    /// 因此切换器激活成功后会同步调用本方法补记，保证下一次枚举 index0 = 刚激活的窗口。
    func noteFocus(wid: CGWindowID) {
        lock.lock()
        activity[wid] = Date()
        lock.unlock()
    }

    // MARK: - 生命周期

    private func observeLifecycle() {
        let ws = NSWorkspace.shared.notificationCenter
        observers = [
            ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.addObserver(for: app.processIdentifier)
            },
            ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.removeObserver(for: app.processIdentifier)
            },
        ]
        // 用户从系统设置返回授权后补建观察者（首次启动时可能尚未授权）
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard AccessibilityPermission.isGranted else { return }
            self?.rebuildObservers()
        }
    }

    private func rebuildObservers() {
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy != .prohibited else { continue }
            addObserver(for: app.processIdentifier)
        }
    }

    private func addObserver(for pid: pid_t) {
        guard AccessibilityPermission.isGranted else { return }
        lock.lock(); let exists = axObservers[pid] != nil; lock.unlock()
        guard !exists else { return }

        let appElement = AXUIElementCreateApplication(pid)
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, info in
            guard let info else { return }
            let tracker = Unmanaged<WindowActivityTracker>.fromOpaque(info).takeUnretainedValue()
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(element, &wid) == .success {
                tracker.noteFocus(wid: wid)
            }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, context) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        lock.lock()
        axObservers[pid] = observer
        lock.unlock()
    }

    private func removeObserver(for pid: pid_t) {
        lock.lock()
        let observer = axObservers.removeValue(forKey: pid)
        lock.unlock()
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }
}
