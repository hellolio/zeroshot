import AppKit
import ApplicationServices
import CoreGraphics

/// Dock 单击最小化：单击前台已激活 app 的 Dock 图标，最小化该 app 的「前台窗口」
/// （聚焦窗口，取不到回退主窗口；聚焦窗口不可最小化时放行交给系统）。
///
/// 实现要点：
/// - 用 CGEventTap 监听左键（按下/拖拽/抬起）+ AX 命中测试识别被点击的 Dock 项；
///   命中前台可最小化 app 时按下即吞掉事件并登记候选。若按下→抬起在 quickClickMaxDuration
///   （400ms）内（且未拖拽），视为快速单击：抬起时最小化并吞掉抬起，避免 macOS
///   「再点 Dock 图标即恢复」抵消最小化结果。
///   超过 400ms 仍按住（或发生拖拽）则把吞掉的按下以合成 mouseDown 交回系统，之后该手势
///   完全交由系统处理（按住弹 Dock 菜单 / 拖动重排 / 慢点击），不再最小化。
/// - 识别走两级：
///   1. 快路径：dock 项 frame 缓存（纯几何 contains，零 AX 调用），布局变化由
///      NSWorkspace 通知防抖重建；
///   2. 兜底：AXUIElementCopyElementAtPosition 单次权威命中测试（免疫放大/自动隐藏/
///      坐标偏移等缓存过期场景）。
/// - 应用身份用 dock 项 kAXURLAttribute（.app file URL → bundleID）而非标题匹配。
/// - option/control 点击让系统手势（App Exposé / 右键菜单）通过，不吞。
/// - 最小化动作异步执行，事件回调内只做识别 + 吞事件，保持热路径毫秒级返回。
final class DockClickMinimizer {
    static let shared = DockClickMinimizer()

    /// 外部通知：由 SettingsStore.dockClickMinimize 的 didSet 触发
    static let didChangeNotification = Notification.Name("zeroflow.dockClickMinimizeDidChange")

    private static let dockBundleID = "com.apple.dock"
    private static let dockItemRole = "AXApplicationDockItem"
    /// 点击点距屏幕边缘该宽度内才认为可能落在 Dock 上（事件路径预筛 VS 全量 AX 遍历）
    private static let edgeMargin: CGFloat = 200
    /// 缓存命中时对 frame 的外扩容差。
    /// 必须为 0：一旦外扩，贴近图标上沿的 Dock 右键菜单项（落在膨胀带内）会被几何快路径
    /// 误判为「点击图标」而吞掉。真实图标边缘的点击由 AX 权威命中测试兜底，不受影响。
    private static let cacheHitInset: CGFloat = 0
    /// 判定「拖拽」的最小位移（pt）：按下后位移超过该值视为拖动 Dock 图标，取消最小化候选
    private static let dragThreshold: CGFloat = 5
    /// 判定「快速单击」的最大时长（s）：按下→抬起 ≤ 该值才触发最小化；
    /// 超过则把吞掉的按下交回系统（按住菜单/拖拽/慢点击由系统处理）。
    private static let quickClickMaxDuration: CFTimeInterval = 0.4
    /// 拖拽时补发给 Dock 的合成 mouseDown 的 source userData 魔数，用于回调里识别并放行
    private static let syntheticDownUserData: UInt64 = 0x5A5A_7A00_0000_0001
    /// 兜底命中测试时向上找 dock 项的父级深度上限
    private static let parentWalkDepth = 8

    private let lock = NSLock()
    private var isRunning = false
    private var thread: Thread?
    private weak var tapRunLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // MARK: - 单击候选（按下登记 → 快速抬起判定；超时/拖拽交回系统）

    private struct PendingClick {
        var app: NSRunningApplication
        var downPoint: CGPoint
        var downTime: CFTimeInterval
    }

    /// 按下时登记的疑似单击候选。事件回调在 tap 线程串行执行，无需加锁。
    private var pendingClick: PendingClick?
    /// 超时交接定时器（挂 tap 线程 runloop，回调也在该线程，无并发问题）。
    private var handOverTimer: CFRunLoopTimer?

    // MARK: - Dock 项缓存

    private struct DockItemEntry {
        var frame: CGRect
        var app: NSRunningApplication?
    }

    private var dockCache: [DockItemEntry] = []
    private var cacheInvalid = true
    private var pendingCacheRebuild: DispatchWorkItem?
    private let cacheQueue = DispatchQueue(label: "zeroflow.dock-cache")
    private var workspaceObservers: [NSObjectProtocol] = []

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidChange(_:)),
            name: Self.didChangeNotification,
            object: nil
        )
        observeDockLayoutChanges()
    }

    /// Dock 布局变化（图标增删、切 Space 等）时置缓存失效并防抖重建
    private func observeDockLayoutChanges() {
        let center = NSWorkspace.shared.notificationCenter
        self.workspaceObservers = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                self?.dockLayoutMayHaveChanged()
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                self?.dockLayoutMayHaveChanged()
            },
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.dockLayoutMayHaveChanged()
            },
        ]
    }

    private func dockLayoutMayHaveChanged() {
        lock.lock()
        cacheInvalid = true
        lock.unlock()
        scheduleCacheRebuild()
    }

    /// trailing-edge 防抖：布局事件爆发时合并为一次重建
    private func scheduleCacheRebuild() {
        let work = DispatchWorkItem { [weak self] in
            self?.rebuildDockCache()
        }
        lock.lock()
        pendingCacheRebuild?.cancel()
        pendingCacheRebuild = work
        lock.unlock()
        cacheQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func rebuildDockCache() {
        lock.lock()
        guard SettingsStore.shared.dockClickMinimize else { lock.unlock(); return }
        lock.unlock()

        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first else { return }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        guard let windows = copyAXElements(dockElement, kAXWindowsAttribute) else { return }

        var items: [DockItemEntry] = []
        for window in windows {
            collectDockApps(in: window, into: &items)
        }
        lock.lock()
        dockCache = items
        cacheInvalid = false
        lock.unlock()
    }

    private func collectDockApps(in element: AXUIElement, into items: inout [DockItemEntry]) {
        if isDockItemElement(element),
           let point = axPoint(element, kAXPositionAttribute),
           let size = axSize(element, kAXSizeAttribute) {
            items.append(DockItemEntry(frame: CGRect(origin: point, size: size), app: appForDockItem(element)))
        }
        if let children = copyAXElements(element, kAXChildrenAttribute) {
            for child in children {
                collectDockApps(in: child, into: &items)
            }
        }
    }

    private func cachedEntry(at point: CGPoint) -> DockItemEntry? {
        lock.lock()
        defer { lock.unlock() }
        guard !cacheInvalid else { return nil }
        // 倒序遍历（后画的在绘制层级更上层）
        for entry in dockCache.reversed()
        where entry.frame.insetBy(dx: -Self.cacheHitInset, dy: -Self.cacheHitInset).contains(point) {
            return entry
        }
        return nil
    }

    // MARK: - 启停

    /// 按开关当前状态启停（启动时 / 开关变化时调用）
    func reapply() {
        if SettingsStore.shared.dockClickMinimize {
            start()
        } else {
            stop()
        }
    }

    @objc private func handleDidChange(_ notification: Notification) {
        reapply()
    }

    private func start() {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        isRunning = true
        lock.unlock()

        dockLayoutMayHaveChanged()

        let t = Thread { [weak self] in
            self?.runTapLoop()
        }
        t.name = "zeroflow.dock-minimize"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    private func stop() {
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        isRunning = false
        let runLoop = tapRunLoop
        let source = runLoopSource
        let tap = eventTap
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        lock.unlock()

        if let source, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopStop(runLoop)
        }
        if let tap { CFMachPortInvalidate(tap) }
        thread = nil
    }

    private func runTapLoop() {
        guard let runLoop = CFRunLoopGetCurrent() else { return }
        lock.lock(); tapRunLoop = runLoop; lock.unlock()
        installTap(in: runLoop)
        // 兜底：tap 创建失败（如权限授权晚了）时周期重试，授权后无需重启即生效
        installRetryTimer(in: runLoop)
        CFRunLoopRun()
    }

    private func installTap(in runLoop: CFRunLoop) {
        let mask = CGEventMask(
            (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
        )
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            ZSLog("DockClickMinimizer: tap create failed (no accessibility permission?)")
            return
        }
        lock.lock(); eventTap = tap; lock.unlock()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        lock.lock(); runLoopSource = source; lock.unlock()
        ZSLog("DockClickMinimizer: tap installed OK, dumping dock layout")
        dumpDockLayout()
    }

    private func installRetryTimer(in runLoop: CFRunLoop) {
        var ctx = CFRunLoopTimerContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let timer = CFRunLoopTimerCreate(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + 2,
            2,
            0,
            0,
            Self.retryTimerCallback,
            &ctx
        )
        if let timer { CFRunLoopAddTimer(runLoop, timer, .commonModes) }
    }

    private func retryCreateTapIfNeeded() {
        lock.lock()
        let missing = eventTap == nil && isRunning
        let runLoop = tapRunLoop
        lock.unlock()
        if missing, let runLoop { installTap(in: runLoop) }
    }

    // MARK: - 事件回调

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        let minimizer = Unmanaged<DockClickMinimizer>.fromOpaque(info).takeUnretainedValue()
        return minimizer.handle(type: type, event: event)
    }

    private static let retryTimerCallback: @convention(c) (CFRunLoopTimer?, UnsafeMutableRawPointer?) -> Void = { _, info in
        guard let info else { return }
        let minimizer = Unmanaged<DockClickMinimizer>.fromOpaque(info).takeUnretainedValue()
        minimizer.retryCreateTapIfNeeded()
    }

    private static let handOverTimerCallback: @convention(c) (CFRunLoopTimer?, UnsafeMutableRawPointer?) -> Void = { timer, info in
        guard let info, let timer else { return }
        let minimizer = Unmanaged<DockClickMinimizer>.fromOpaque(info).takeUnretainedValue()
        minimizer.handOverTimerDidFire(timer)
    }

    // MARK: - 独立诊断探针（ZEROFLOW_DOCK_PROBE=1 启动时执行）

    static func runProbe() {
        ZSLog("DOCK-PROBE begin, AX trusted = \(AccessibilityPermission.isGranted)")
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: dockBundleID).first else {
            ZSLog("DOCK-PROBE: dock NOT found")
            return
        }
        ZSLog("DOCK-PROBE: dock pid=\(dock.processIdentifier) name=\(dock.localizedName ?? "?")")

        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
        let rawType = raw.map { String(describing: type(of: $0)) } ?? "nil"
        ZSLog("DOCK-PROBE: copy kAXWindows -> err=\(err.rawValue), raw=\(rawType)")
        guard err == .success, let raw else { return }

        let array = raw as! CFArray
        ZSLog("DOCK-PROBE: windows count=\(CFArrayGetCount(array))")
        for i in 0..<CFArrayGetCount(array) {
            guard let ptr = CFArrayGetValueAtIndex(array, i) else { continue }
            let win = Unmanaged<AXUIElement>.fromOpaque(ptr).takeUnretainedValue()
            ZSLog("DOCK-PROBE: -- window \(i) --")
            probeAXTree(win, depth: 0)
        }

        // 方法二：直接命中测试系统级元素，扫描底部 Dock 区域各点
        ZSLog("DOCK-PROBE: elementAtPosition scan along BOTTOM edge (top-left coords)")
        if let main = NSScreen.screens.first {
            let frame = topLeftFrameOfScreen(main)
            let scale = main.backingScaleFactor
            ZSLog("DOCK-PROBE: main screen topLeft frame=\(frame) scale=\(scale)")
            // 点坐标：底部 y∈[maxY-120, maxY]，步长 10
            for y in stride(from: frame.maxY - 120, through: frame.maxY - 6, by: 10) {
                for x in stride(from: frame.minX + 80, through: frame.maxX - 80, by: 260) {
                    probeElementAtPosition(x: x, y: y)
                }
            }
            // 像素坐标（Retina 2x）：主屏 2940x1912，底部 y 相应放大
            if scale > 1 {
                ZSLog("DOCK-PROBE: scan in PIXEL coords (scale \(scale))")
                for y in stride(from: (frame.maxY * scale) - 240, through: (frame.maxY * scale) - 12, by: 20) {
                    for x in stride(from: (frame.minX + 160) * scale, through: (frame.maxX - 160) * scale, by: 520) {
                        probeElementAtPosition(x: x, y: y)
                    }
                }
            }
        }
        ZSLog("DOCK-PROBE end")
    }

    private static func probeElementAtPosition(x: CGFloat, y: CGFloat) {
        let systemWide = AXUIElementCreateSystemWide()
        var el: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(systemWide, Float(x), Float(y), &el)
        guard err == .success, let el else {
            ZSLog("DOCK-PROBE elemAt(\(Int(x)),\(Int(y))) err=\(err.rawValue)")
            return
        }
        var roleRaw: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRaw)
        let role = roleRaw as? String ?? "?"
        var titleRaw: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &titleRaw)
        let title = titleRaw as? String ?? ""
        var subroleRaw: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subroleRaw)
        let subrole = subroleRaw as? String ?? ""
        var parentRaw: CFTypeRef?
        var parentRole = "-"
        if AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parentRaw) == .success,
           let parentRaw {
            var pr: CFTypeRef?
            if AXUIElementCopyAttributeValue(parentRaw as! AXUIElement, kAXRoleAttribute as CFString, &pr) == .success,
               let pr { parentRole = pr as? String ?? "-" }
        }
        ZSLog("DOCK-PROBE elemAt(\(Int(x)),\(Int(y))) role=\(role) subrole=\(subrole) title='\(title)' parentRole=\(parentRole)")
    }

    /// 把 NSScreen frame（左下原点）转为主屏左上原点（与 CGEvent/AX 全局坐标一致）
    private static func topLeftFrameOfScreen(_ screen: NSScreen) -> CGRect {
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        return CGRect(x: screen.frame.minX,
                      y: union.maxY - screen.frame.maxY,
                      width: screen.frame.width,
                      height: screen.frame.height)
    }

    private static func probeAXTree(_ el: AXUIElement, depth: Int) {
        if depth > 8 { return }
        var roleRaw: CFTypeRef?
        let rerr = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRaw)
        let role = roleRaw as? String ?? "?(err=\(rerr.rawValue))"
        var titleRaw: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &titleRaw)
        let title = (titleRaw as? String) ?? ""
        ZSLog("DOCK-PROBE \(String(repeating: "  ", count: depth))role=\(role) title='\(title)'")
        if role == "AXApplicationDockItem" { return }
        var kidsRaw: CFTypeRef?
        let kerr = AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRaw)
        guard kerr == .success, let kids = kidsRaw else { return }
        let array = kids as! CFArray
        let n = CFArrayGetCount(array)
        for i in 0..<min(n, 30) {
            guard let p = CFArrayGetValueAtIndex(array, i) else { continue }
            probeAXTree(Unmanaged<AXUIElement>.fromOpaque(p).takeUnretainedValue(), depth: depth + 1)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let tap = eventTap; lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard SettingsStore.shared.dockClickMinimize else { return Unmanaged.passUnretained(event) }
        // 未授权辅助功能时静默跳过，不做任何处理
        guard AccessibilityPermission.isGranted else { return Unmanaged.passUnretained(event) }

        switch type {
        case .leftMouseDown:
            return handleMouseDown(event)
        case .leftMouseDragged:
            return handleMouseDragged(event)
        case .leftMouseUp:
            return handleMouseUp(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// 按下：命中前台可最小化 app 时吞掉该事件并登记候选；
    /// 抬起时若期间未发生拖拽（纯单击）则最小化，发生拖拽则在拖拽分支补发合成按下给 Dock。
    private func handleMouseDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        // 我们自己补发的合成 mouseDown：直接放行，不做识别也不吞
        if event.getIntegerValueField(.eventSourceUserData) == Int64(Self.syntheticDownUserData) {
            return Unmanaged.passUnretained(event)
        }
        // option/control 点击让系统手势（App Exposé / 右键菜单）通过，不吞
        let flags = event.flags
        if flags.contains(.maskAlternate) || flags.contains(.maskControl) {
            pendingClick = nil
            return Unmanaged.passUnretained(event)
        }

        let point = event.location
        guard isNearDockEdge(point) else {
            pendingClick = nil
            return Unmanaged.passUnretained(event)
        }

        guard let app = appFromDockItem(at: point) else {
            pendingClick = nil
            logThrottled("DockClickMinimizer: edge click at \(point) hit no dock app item")
            return Unmanaged.passUnretained(event)
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            pendingClick = nil
            ZSLog("DockClickMinimizer: dock item app but no frontmost app")
            return Unmanaged.passUnretained(event)
        }
        guard app.processIdentifier == frontmost.processIdentifier else {
            pendingClick = nil
            ZSLog("DockClickMinimizer: dock app '\(app.localizedName ?? "?")' != frontmost '\(frontmost.localizedName ?? "?")', skip")
            return Unmanaged.passUnretained(event)
        }

        // 已全屏 / 无可见窗口时不吞，交给系统默认行为（含「再点即恢复」）
        guard shouldMinimize(app) else {
            pendingClick = nil
            ZSLog("DockClickMinimizer: matched '\(app.localizedName ?? "?")' but no minimizable window (all minimized/fullscreen?)")
            return Unmanaged.passUnretained(event)
        }

        pendingClick = PendingClick(app: app, downPoint: point, downTime: CFAbsoluteTimeGetCurrent())
        // 吞掉按下：Dock 收不到该单击，避免长按弹右键菜单、也不会「再点即恢复」抵消最小化
        startHandOverTimer()
        return nil
    }

    /// 启动超时交接定时器：按下超过 quickClickMaxDuration 仍未抬起 → 把吞掉的按下交回系统。
    private func startHandOverTimer() {
        cancelHandOverTimer()
        guard let runLoop = CFRunLoopGetCurrent() else { return }
        var ctx = CFRunLoopTimerContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let timer = CFRunLoopTimerCreate(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + Self.quickClickMaxDuration,
            0,
            0,
            0,
            Self.handOverTimerCallback,
            &ctx
        )
        if let timer {
            handOverTimer = timer
            CFRunLoopAddTimer(runLoop, timer, .commonModes)
        }
    }

    private func cancelHandOverTimer() {
        if let timer = handOverTimer {
            CFRunLoopTimerInvalidate(timer)
            handOverTimer = nil
        }
    }

    private func handOverTimerDidFire(_ timer: CFRunLoopTimer) {
        // 候选已被抬起/拖拽/取消时（timer 可能已失效）直接忽略
        guard let pending = pendingClick else {
            cancelHandOverTimer()
            return
        }
        // 按住未动：位置与按下点一致，用 downPoint 交接（保持左上原点坐标系，避免坐标换算）
        handOverToSystem(at: pending.downPoint)
    }

    /// 超时交接：仍按着（未抬起也未拖拽）超过 quickClickMaxDuration，
    /// 清除候选并把吞掉的按下以合成 mouseDown 交回系统，之后该手势全归系统处理。
    private func handOverToSystem(at point: CGPoint) {
        guard pendingClick != nil else { return }
        pendingClick = nil
        cancelHandOverTimer()
        postSyntheticMouseDown(at: point)
    }

    /// 拖拽：位移超过阈值视为拖动 Dock 图标，取消候选，并向 Dock 补发合成 mouseDown
    /// （Dock 收到 down 后，后续放行的真实 dragged/up 即构成一次完整拖拽手势，图标重排正常）。
    private func handleMouseDragged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let pending = pendingClick else { return Unmanaged.passUnretained(event) }
        let point = event.location
        if max(abs(point.x - pending.downPoint.x), abs(point.y - pending.downPoint.y)) > Self.dragThreshold {
            cancelHandOverTimer()
            pendingClick = nil
            postSyntheticMouseDown(at: point)
        }
        return Unmanaged.passUnretained(event)
    }

    /// 补发一个合成 leftMouseDown 到 HID 事件流，让 Dock 由此开始拖拽跟踪。
    /// source 带上魔数 userData，回调据此放行，避免把该合成事件当成新单击吞掉。
    private func postSyntheticMouseDown(at point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        source.userData = Int64(Self.syntheticDownUserData)
        let synthetic = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        synthetic?.post(tap: .cghidEventTap)
        ZSLog("DockClickMinimizer: drag detected, replayed synthetic mouseDown at \(point)")
    }

    /// 抬起：候选仍在且为快速单击（≤ quickClickMaxDuration）才最小化并吞掉抬起；
    /// 超时已被交回系统 / 拖拽被取消则放行，由系统完成该手势。
    private func handleMouseUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let pending = pendingClick else { return Unmanaged.passUnretained(event) }
        defer { cancelHandOverTimer() }
        let app = pending.app

        let elapsed = CFAbsoluteTimeGetCurrent() - pending.downTime
        guard elapsed <= Self.quickClickMaxDuration else {
            // 超过 400ms 离开：不算快速单击，不再最小化（此时按下已由定时器交回系统，放行）
            pendingClick = nil
            ZSLog("DockClickMinimizer: slow release (\(Int(elapsed * 1000))ms) of '\(app.localizedName ?? "?")', handing back to system")
            return Unmanaged.passUnretained(event)
        }

        pendingClick = nil
        ZSLog("DockClickMinimizer: minimized \(app.localizedName ?? "?"), swallowed mouseUp")
        // 吞掉该次抬起，避免系统「再点 Dock 图标即恢复」抵消最小化；
        // 最小化动作异步执行，事件回调保持轻量
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.minimizeFrontmostAppWindows(app)
        }
        return nil
    }

    private var lastNoHitLog = CFAbsoluteTime(0)
    private func logThrottled(_ message: String) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastNoHitLog > 5 else { return }
        lastNoHitLog = now
        ZSLog(message)
    }

    // MARK: - Dock 项识别

    /// 返回点击点对应的 Dock 项 app（快路径缓存命中优先，未命中走 AX 权威命中测试）
    private func appFromDockItem(at point: CGPoint) -> NSRunningApplication? {
        if let entry = cachedEntry(at: point),
           let app = entry.app {
            return app
        }
        return appFromHitTest(at: point)
    }

    /// AX 命中测试：直接问系统「该点上是什么元素」，再向上找最近的 Dock 项
    private func appFromHitTest(at point: CGPoint) -> NSRunningApplication? {
        let systemWide = AXUIElementCreateSystemWide()
        var raw: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &raw) == .success,
              let raw else { return nil }
        var el = raw
        for _ in 0..<Self.parentWalkDepth {
            if isDockItemElement(el) {
                return appForDockItem(el)
            }
            // 命中点落在 Dock 图标右键菜单/菜单项上：其祖先链上挂着 AXApplicationDockItem，
            // 若放行会被误判成「单击图标」而最小化。遇到菜单元素一律视为非图标点击，放行。
            if isMenuElement(el) {
                return nil
            }
            guard let parent = axParent(el) else { break }
            el = parent
        }
        return nil
    }

    /// 菜单类元素：Dock 图标右键弹出的菜单/菜单项（含「选项」子菜单）。
    /// 点击落在这些元素上时，绝不触发 Dock 单击最小化。真实图标点击的祖先链不会经过菜单元素。
    private func isMenuElement(_ el: AXUIElement) -> Bool {
        let role = copyAXValue(el, kAXRoleAttribute, as: CFString.self) as String?
        let subrole = copyAXValue(el, kAXSubroleAttribute, as: CFString.self) as String?
        switch role ?? subrole {
        case kAXMenuRole, kAXMenuItemRole, kAXMenuBarRole, kAXMenuBarItemRole:
            return true
        default:
            return false
        }
    }

    private func isDockItemElement(_ el: AXUIElement) -> Bool {
        if let role = copyAXValue(el, kAXRoleAttribute, as: CFString.self) as String?,
           role == Self.dockItemRole {
            return true
        }
        if let subrole = copyAXValue(el, kAXSubroleAttribute, as: CFString.self) as String?,
           subrole == Self.dockItemRole {
            return true
        }
        return false
    }

    private func axParent(_ el: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &raw) == .success,
              let raw else { return nil }
        // AX 元素的父元素恒为 AXUIElement，强制桥接（与 probeAXTree 中 parentRaw 的处理一致）
        let parent: AXUIElement = raw as! AXUIElement
        return parent
    }

    /// Dock 项 → 对应运行中的应用。优先 kAXURL（.app file URL → bundleID），
    /// 无 URL 的项（Launchpad/Trash/窗口图标等）按标题兜底匹配。
    private func appForDockItem(_ el: AXUIElement) -> NSRunningApplication? {
        if let urlRaw = copyAXValue(el, kAXURLAttribute, as: NSURL.self),
           let bundle = Bundle(url: urlRaw as URL),
           let bundleID = bundle.bundleIdentifier,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app
        }
        if let title = copyAXValue(el, kAXTitleAttribute, as: CFString.self) as String? {
            return runningApp(named: title)
        }
        return nil
    }

    private func runningApp(named title: String) -> NSRunningApplication? {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return NSWorkspace.shared.runningApplications.first { app in
            let displayName = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let executableName = app.executableURL?.deletingPathExtension().lastPathComponent.lowercased()
            return displayName == normalized || executableName == normalized
        }
    }

    // MARK: - 坐标（CGEvent/AX/CGWindow 均为「主屏左上原点」的点坐标）

    private func topLeftFrame(of screen: NSScreen) -> CGRect {
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        return CGRect(
            x: screen.frame.minX,
            y: union.maxY - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

    private func isNearDockEdge(_ point: CGPoint) -> Bool {
        for frame in NSScreen.screens.map({ topLeftFrame(of: $0) }) where frame.contains(point) {
            if point.x < frame.minX + Self.edgeMargin || point.x > frame.maxX - Self.edgeMargin { return true }
            if point.y < frame.minY + Self.edgeMargin || point.y > frame.maxY - Self.edgeMargin { return true }
            return false
        }
        return false
    }

    // MARK: - AX 辅助

    private func copyAXValue<T>(_ element: AXUIElement, _ attribute: String, as _: T.Type) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw else { return nil }
        return value as? T
    }

    private func copyAXElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw else { return nil }
        return value as? [AXUIElement]
    }

    private func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copyAXValue(element, attribute, as: AXValue.self) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private func axSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copyAXValue(element, attribute, as: AXValue.self) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    /// 诊断：打印一次 Dock 的 AX 布局（窗口 + 各 dock 项 frame），排查坐标空间问题
    private func dumpDockLayout() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first else {
            ZSLog("DockClickMinimizer.dump: no dock app")
            return
        }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        guard let windows = copyAXElements(dockElement, kAXWindowsAttribute) else {
            ZSLog("DockClickMinimizer.dump: no dock windows (AX denied?)")
            return
        }
        for (wi, window) in windows.enumerated() {
            var items: [DockItemEntry] = []
            collectDockApps(in: window, into: &items)
            let wpos = axPoint(window, kAXPositionAttribute).map { "(\($0.x), \($0.y))" } ?? "?"
            let wsize = axSize(window, kAXSizeAttribute).map { "\($0.width)x\($0.height)" } ?? "?"
            ZSLog("DockClickMinimizer.dump: window[\(wi)] pos=\(wpos) size=\(wsize) items=\(items.count)")
            for item in items {
                let name = item.app?.localizedName ?? "?"
                ZSLog("DockClickMinimizer.dump:   '\(name)' frame=\(item.frame)")
            }
        }
    }

    // MARK: - 最小化

    /// 吞事件前的快速判断：该 app 是否存在可最小化的「前台窗口」。
    /// 纯 AX 枚举，不依赖 CGWindowList（后者在无屏幕录制权限时拿不到其他 app 窗口，
    /// 曾经的根因）。
    private func shouldMinimize(_ app: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let onScreenFrames = NSScreen.screens.map { topLeftFrame(of: $0) }
        let found = frontMinimizableWindow(of: appElement, onScreenFrames: onScreenFrames) != nil
        ZSLog("DockClickMinimizer.shouldMinimize(\(app.localizedName ?? "?")): minimizable-front=\(found)")
        return found
    }

    /// 返回 app 的可最小化「前台窗口」：聚焦窗口（kAXFocusedWindow，即最近操作的窗口）优先，
    /// 取不到再回退主窗口（kAXMainWindow）。
    /// 候选存在但不可最小化（如全屏/已最小化）时返回 nil —— 不回退到其他窗口，交给系统默认行为。
    private func frontMinimizableWindow(of appElement: AXUIElement, onScreenFrames: [CGRect]) -> AXUIElement? {
        if let focused = copyAXValue(appElement, kAXFocusedWindowAttribute, as: AXUIElement.self) {
            return isMinimizable(focused, onScreenFrames: onScreenFrames) ? focused : nil
        }
        if let main = copyAXValue(appElement, kAXMainWindowAttribute, as: AXUIElement.self) {
            return isMinimizable(main, onScreenFrames: onScreenFrames) ? main : nil
        }
        return nil
    }

    /// 最小化 app 的前台（聚焦）窗口。
    /// 异步执行：不在事件回调内跑多窗口 AX 写入。
    private func minimizeFrontmostAppWindows(_ app: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let onScreenFrames = NSScreen.screens.map { topLeftFrame(of: $0) }
        guard let window = frontMinimizableWindow(of: appElement, onScreenFrames: onScreenFrames) else { return false }
        return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
    }

    /// 窗口是否可最小化：非最小化、非全屏、且与某块屏幕的框架有重叠（丢弃几何离屏窗口）
    private func isMinimizable(_ window: AXUIElement, onScreenFrames: [CGRect]) -> Bool {
        if isMinimized(window) { return false }
        guard let point = axPoint(window, kAXPositionAttribute),
              let size = axSize(window, kAXSizeAttribute) else { return false }
        let bounds = CGRect(origin: point, size: size)
        if isFullScreen(window, bounds: bounds) { return false }
        return onScreenFrames.contains { $0.insetBy(dx: -10, dy: -10).intersects(bounds) }
    }

    private func isFullScreen(_ window: AXUIElement, bounds: CGRect) -> Bool {
        if let full = copyAXValue(window, "AXFullScreen", as: CFBoolean.self),
           CFBooleanGetValue(full) {
            return true
        }
        // 兜底：部分窗口不支持 AXFullScreen，用「铺满某块屏幕」近似——
        // 窗口边界要覆盖整块屏幕（内缩 4pt）才算全屏，而非窗口落在屏幕内
        return NSScreen.screens.contains { bounds.contains(topLeftFrame(of: $0).insetBy(dx: 4, dy: 4)) }
    }

    private func isMinimized(_ window: AXUIElement) -> Bool {
        guard let value = copyAXValue(window, kAXMinimizedAttribute, as: CFBoolean.self) else { return false }
        return CFBooleanGetValue(value)
    }
}