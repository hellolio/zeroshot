import AppKit
import CoreGraphics
import ScreenCaptureKit

/// 屏幕录制权限检测
enum ScreenRecordingPermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 真实权限探测：尝试获取可共享屏幕内容。与截图走同一权限路径，避免 preflight 缓存误判。
    static func hasScreenCaptureAccess() async -> Bool {
        if ProcessInfo.processInfo.environment["ZEROSHOT_FAKE_PERMISSION"] == "1" {
            ZSLog("FAKE permission granted (debug)")
            return true
        }
        do {
            _ = try await SCShareableContent.current
            return true
        } catch {
            ZSLog("hasScreenCaptureAccess error: \(error)")
            return false
        }
    }

    static func requestAuthorization() {
        CGRequestScreenCaptureAccess()
    }
}

/// 屏幕截图捕获（macOS 14+ 使用 ScreenCaptureKit）
enum ScreenCapture {
    /// 捕获指定屏幕上的区域
    /// - Parameters:
    ///   - screen: 目标 NSScreen
    ///   - rect: 该屏幕窗口坐标系内的矩形（左下原点，即 SwiftUI/NSScreen 内部坐标）
    static func capture(screen: NSScreen, rect: CGRect) async -> NSImage? {
        let normalized = CGRect(x: rect.minX, y: rect.minY,
                                width: abs(rect.width), height: abs(rect.height))
        return await captureWithScreenCaptureKit(screen: screen, rect: normalized)
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return CGMainDisplayID()
        }
        return number.uint32Value
    }

    /// 转换：把屏幕内部（左下原点）的矩形转为该屏「左上原点」的逻辑坐标
    private static func topLeftRect(in screen: NSScreen, rect: CGRect) -> CGRect {
        let globalX = screen.frame.minX + rect.minX
        let globalBottomY = screen.frame.minY + rect.minY
        let topInScreen = screen.frame.maxY - globalBottomY - rect.height
        let leftInScreen = globalX - screen.frame.minX
        return CGRect(x: leftInScreen, y: topInScreen, width: rect.width, height: rect.height)
    }

    // MARK: - ScreenCaptureKit

    private static func captureWithScreenCaptureKit(screen: NSScreen, rect: CGRect) async -> NSImage? {
        do {
            let content = try await SCShareableContent.current
            ZSLog("SCShareableContent OK, \(content.displays.count) display(s)")
            let displayID = displayID(for: screen)
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                ZSLog("no SC display for id \(displayID)")
                return nil
            }
            let scale = screen.backingScaleFactor
            let sourceRect = topLeftRect(in: screen, rect: rect)

            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(rect.width * scale)
            config.height = Int(rect.height * scale)
            config.showsCursor = false
            config.sourceRect = sourceRect
            ZSLog("SC config: w=\(config.width) h=\(config.height) source=\(sourceRect)")

            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return NSImage(cgImage: cgImage,
                           size: NSSize(width: CGFloat(cgImage.width) / scale,
                                        height: CGFloat(cgImage.height) / scale))
        } catch {
            ZSLog("SCScreenshotManager error: \(error)")
            return nil
        }
    }
}