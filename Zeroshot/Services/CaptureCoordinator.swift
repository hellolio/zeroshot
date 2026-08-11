import AppKit
import SwiftUI

/// SLK：串联「选区 → 捕获 → 打开编辑器」的协调器
final class CaptureCoordinator: ObservableObject {
    static let shared = CaptureCoordinator()

    /// 当前是否正在截图会话中
    private(set) var isActive = false

    private var overlayWindows: [CaptureOverlayWindow] = []
    private var editorController: NSWindowController?

    private init() {}

    // MARK: - 入口

    /// 开始一次截图（由热键 / 菜单触发）
    func startCapture() {
        ZSLog("startCapture called, preflight granted = \(ScreenRecordingPermission.isGranted)")
        guard !isActive else { ZSLog("already active, ignore"); return }
        guard SettingsStore.shared.screenshotEnabled else {
            ZSLog("screenshot disabled, ignore")
            return
        }
        isActive = true
        Task {
            // 用真实权限探测：与截图使用同一 ScreenCaptureKit API
            let granted = await ScreenRecordingPermission.hasScreenCaptureAccess()
            await MainActor.run {
                guard granted else {
                    ZSLog("real permission check failed -> guide")
                    self.isActive = false
                    self.presentPermissionGuide()
                    return
                }
                ZSLog("real permission OK -> create overlays")
                // 进入截图的那一刻就把光标切成十字线
                NSCursor.crosshair.set()
                self.createOverlayWindows()
            }
        }
    }

    // MARK: - 权限引导

    /// 无截屏权限时不弹窗，改为打开设置页的「截图」标签页展示权限引导
    private func presentPermissionGuide() {
        ZSLog("presentPermissionGuide: open settings")
        NotificationCenter.default.post(name: .zeroshotOpenSettings, object: nil)
    }

    // MARK: - 覆盖层

    private func createOverlayWindows() {
        // 首次截图时 app 可能尚未激活，键盘事件不会投递给遮罩的 key 窗口，
        // 导致按 Esc 无法取消选区。进入选区前先激活本应用。
        NSApp.activate(ignoringOtherApps: true)
        let screens = NSScreen.screens
        ZSLog("creating overlay for \(screens.count) screen(s)")
        overlayWindows = screens.map { screen in
            ZSLog("overlay window for screen \(screen.frame)")
            let window = CaptureOverlayWindow(screen: screen) { [weak self] rect in
                ZSLog("selection completed: \(rect) on screen frame \(screen.frame)")
                self?.completeSelection(on: screen, rect: rect)
            } onCancel: { [weak self] in
                ZSLog("selection cancelled")
                self?.cancelSelection()
            }
            window.orderFrontRegardless()
            return window
        }

        // 把光标放置到最前面一个屏幕。若鼠标存在的屏幕优先。
        if let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
           let win = overlayWindows.first(where: { $0.screen?.frame == mouseScreen.frame }) {
            win.makeKey()
        }
    }

    private func completeSelection(on screen: NSScreen, rect: CGRect) {
        guard let window = overlayWindow(for: screen) else { return }
        window.orderOut(nil)
        isActive = false
        teardownOverlays()

        Task {
            ZSLog("capturing screen=\(screen.frame) rect=\(rect)")
            guard let image = await ScreenCapture.capture(screen: screen, rect: rect) else {
                ZSLog("capture returned nil")
                await MainActor.run { self.presentCaptureError() }
                return
            }
            ZSLog("capture OK size=\(image.size)")
            await MainActor.run {
                self.openEditor(image: image)
            }
        }
    }

    private func cancelSelection() {
        isActive = false
        teardownOverlays()
    }

    /// 延迟到下一轮事件循环再关闭遮罩窗口，避免在 keyDown/mouseUp 事件处理中
    /// close 正在派发事件的窗口导致释放后用崩溃（EXC_BAD_ACCESS）。
    private func teardownOverlays() {
        let windows = overlayWindows
        overlayWindows = []
        DispatchQueue.main.async {
            windows.forEach { $0.orderOut(nil) }
            NSCursor.arrow.set()
            windows.forEach { $0.close() }
        }
    }

    private func overlayWindow(for screen: NSScreen) -> CaptureOverlayWindow? {
        overlayWindows.first { $0.screen === screen }
    }

    private func presentCaptureError() {
        let alert = NSAlert()
        alert.messageText = "截图失败"
        alert.informativeText = "无法捕获所选区域，请检查屏幕录制权限后重试。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好的")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - 编辑器

    /// 调试专用：直接打开编辑页（绕过取景权限），用一张合成网格图测试标注
    func openEditorForDebug() {
        ZSLog("openEditorForDebug: synthetic 800x500 image")
        let size = NSSize(width: 800, height: 500)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.lightGray.withAlphaComponent(0.5).setStroke()
        for x in stride(from: CGFloat(0), through: size.width, by: 50) {
            NSBezierPath(rect: NSRect(x: x, y: 0, width: 1, height: size.height)).stroke()
        }
        for y in stride(from: CGFloat(0), through: size.height, by: 50) {
            NSBezierPath(rect: NSRect(x: 0, y: y, width: size.width, height: 1)).stroke()
        }
        image.unlockFocus()
        self.openEditor(image: image)
    }

    private func openEditor(image: NSImage) {
        if let controller = editorController {
            controller.close()
        }

        // 计算真实顶栏（标题栏）高度，让底部工具栏与之保持一致
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable]
        let sampleFrame = NSRect(x: 0, y: 0, width: 100, height: 100)
        let contentRect = NSWindow.contentRect(forFrameRect: sampleFrame, styleMask: styleMask)
        let titleBarHeight = sampleFrame.height - contentRect.height

        let hosting = NSHostingController(rootView: EditorView(
            image: image,
            onClose: {
                self.editorController?.close()
                self.editorController = nil
            },
            barHeight: titleBarHeight
        ))

        let window = NSWindow(contentViewController: hosting)
        window.title = "zeroshot 截图"
        window.styleMask = styleMask
        window.isRestorable = false

        // 窗口初始尺寸根据截图自适应：
        // - 截图较小 → 窗口贴着截图大小（避免大片空白）
        // - 截图较大 → 缩放到窗口尺寸上限（避免显示不完）
        let imgSize = image.size
        let toolbarHeight: CGFloat = 64
        let maxW: CGFloat = 1100
        let maxH: CGFloat = 760
        // 最小宽度需保证底部工具栏所有按钮（撤销/重做/画线/标注/矩形/圆框/马赛克/颜色/粗细/下载/复制）完整显示
        let minW: CGFloat = 720
        let minH: CGFloat = 300

        var contentW = imgSize.width
        var contentH = imgSize.height + toolbarHeight
        let maxScale = min(maxW / max(contentW, 1), maxH / max(contentH, 1))
        if maxScale < 1 {
            contentW *= maxScale
            contentH *= maxScale
        }
        contentW = max(minW, min(contentW, maxW))
        contentH = max(minH, min(contentH, maxH))
        window.setContentSize(NSSize(width: contentW, height: contentH))
        window.minSize = NSSize(width: minW, height: minH)
        window.center()
        window.isRestorable = false

        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 强制在窗口显示后立即布局渲染，避免首次打开出现空白
        window.contentView?.needsLayout = true
        window.contentView?.needsDisplay = true
        window.displayIfNeeded()
        editorController = controller
    }
}