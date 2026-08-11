import SwiftUI
import AppKit

/// 覆盖在屏幕上的选区遮罩视图（SwiftUI）
struct CaptureOverlayView: NSViewRepresentable {
    var screen: NSScreen
    var onComplete: (CGRect) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CaptureOverlayNSView(screen: screen)
        view.onComplete = onComplete
        view.onCancel = onCancel
        view.setupTracking()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 基于 NSView 的遮罩：绘制遮罩 + 选区矩形 + 尺寸提示
final class CaptureOverlayNSView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private let screen: NSScreen
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?

    private var isCapturing = false
    private var trackingArea: NSTrackingArea?

    private let dimColor = NSColor.black.withAlphaComponent(0.35)
    private let borderColor = NSColor.systemBlue

    init(screen: NSScreen) {
        self.screen = screen
        super.init(frame: screen.frame)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func setupTracking() {
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.makeFirstResponder(self)
        window.invalidateCursorRects(for: self)
    }

    /// 首次点击即可接收事件并把窗口变成 key 窗口（否则边窗口无标题栏无法成为 key）
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 鼠标进入选区视图时统一显示十字光标（离开后自动恢复原光标）
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        startPoint = p
        currentPoint = p
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard startPoint != nil else { return }
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = startPoint else { return }
        let end = convert(event.locationInWindow, from: nil)
        startPoint = nil
        currentPoint = nil

        let rect = rect(from: start, to: end)
        if rect.width < 1 && rect.height < 1 {
            onComplete?(CGRect(origin: .zero, size: screen.frame.size))
        } else if rect.width >= 1 && rect.height >= 1 {
            onComplete?(rect)
        } else {
            onCancel?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    private func rect(from a: NSPoint, to b: NSPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 全屏遮罩
        ctx.setFillColor(dimColor.cgColor)
        ctx.fill(bounds)

        guard let start = startPoint, let current = currentPoint else { return }
        let sel = rect(from: start, to: current)

        // 清除选区内遮罩（用 clear）
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.setFillColor(NSColor.clear.cgColor)
        ctx.fill(sel)
        ctx.restoreGState()

        // 选区边框
        ctx.setStrokeColor(borderColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(sel)

        // 尺寸提示
        let sizeText = "\(Int(sel.width)) × \(Int(sel.height))"
        let textAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = (sizeText as NSString).size(withAttributes: textAttr)
        let textRect = NSRect(x: sel.maxX + 4, y: sel.minY + 2,
                              width: textSize.width + 8, height: textSize.height + 4)

        let bg = NSBezierPath(roundedRect: textRect, xRadius: 3, yRadius: 3)
        NSColor.black.withAlphaComponent(0.6).setFill()
        bg.fill()
        (sizeText as NSString).draw(
            at: NSPoint(x: textRect.minX + 4, y: textRect.minY + 2),
            withAttributes: textAttr
        )
    }
}

/// 单个屏幕的选区窗口
final class CaptureOverlayWindow: NSWindow {
    init(screen: NSScreen,
         onComplete: @escaping (CGRect) -> Void,
         onCancel: @escaping () -> Void) {
        super.init(contentRect: NSRect(origin: .zero, size: screen.frame.size),
                   styleMask: .borderless, backing: .buffered, defer: false)
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.acceptsMouseMovedEvents = true
        self.animationBehavior = .none
        self.isReleasedWhenClosed = false
        self.setFrame(screen.frame, display: false)

        let overlay = CaptureOverlayNSView(screen: screen)
        overlay.onComplete = onComplete
        overlay.onCancel = onCancel
        overlay.setupTracking()
        self.contentView = overlay
    }

    /// 无边框窗口默认不能成为 key 窗口，导致收不到键盘事件（Esc 无效），必须放开
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}