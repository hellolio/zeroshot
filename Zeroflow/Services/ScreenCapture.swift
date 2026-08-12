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
        if ProcessInfo.processInfo.environment["ZEROFLOW_FAKE_PERMISSION"] == "1" {
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

/// 整屏捕获结果：原生像素 CGImage + 该屏缩放系数，供选区后裁剪
struct DisplayCapture {
    let cgImage: CGImage
    /// 该屏缩放系数（contentFilter.pointPixelScale，macOS 14+）
    let pixelScale: CGFloat
}

/// 屏幕截图捕获（macOS 14+ 使用 ScreenCaptureKit）
enum ScreenCapture {
    /// 捕获指定屏幕上的区域（预拍缺失时的实时兜底入口）
    /// - Parameters:
    ///   - screen: 目标 NSScreen
    ///   - rect: 该屏幕窗口坐标系内的矩形（左下原点，即 SwiftUI/NSScreen 内部坐标）
    static func capture(screen: NSScreen, rect: CGRect) async -> NSImage? {
        let normalized = CGRect(x: rect.minX, y: rect.minY,
                                width: abs(rect.width), height: abs(rect.height))
        guard let capture = await captureFullDisplay(screen: screen) else { return nil }
        return crop(capture, on: screen, rect: normalized)
    }

    /// 整屏捕获（原生像素、无损，不设 sourceRect——那是 ScreenCaptureKit 掉分辨率的根因）
    static func captureFullDisplay(screen: NSScreen) async -> DisplayCapture? {
        let displayID = displayID(for: screen)
        guard let filter = await contentFilter(for: displayID) else { return nil }

        let pixelScale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * pixelScale)
        config.height = Int(filter.contentRect.height * pixelScale)
        config.showsCursor = false
        config.captureResolution = .best

        do {
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            ZSLog("SC full capture: \(cgImage.width)x\(cgImage.height) px scale=\(pixelScale)")
            return DisplayCapture(cgImage: cgImage, pixelScale: pixelScale)
        } catch {
            ZSLog("SCScreenshotManager error: \(error)")
            return nil
        }
    }

    /// 从整屏捕获中裁出选区。选区 rect 为屏幕内左下原点坐标，转为左上原点后再按像素缩放裁剪。
    static func crop(_ capture: DisplayCapture, on screen: NSScreen, rect: CGRect) -> NSImage {
        let topLeft = topLeftRect(in: screen, rect: rect)
        let px = CGRect(x: topLeft.minX * capture.pixelScale,
                        y: topLeft.minY * capture.pixelScale,
                        width: topLeft.width * capture.pixelScale,
                        height: topLeft.height * capture.pixelScale)
        let bounds = CGRect(x: 0, y: 0,
                            width: CGFloat(capture.cgImage.width),
                            height: CGFloat(capture.cgImage.height))
        let clipped = px.intersection(bounds)
        guard clipped.width >= 1, clipped.height >= 1,
              let cropped = capture.cgImage.cropping(to: clipped) else { return NSImage() }
        return NSImage(cgImage: cropped,
                       size: NSSize(width: CGFloat(cropped.width) / capture.pixelScale,
                                    height: CGFloat(cropped.height) / capture.pixelScale))
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

    // MARK: - SCShareableContent / ContentFilter 缓存

    /// `SCShareableContent.current` 每次调用都会全量枚举窗口/显示器，耗时可达数百毫秒，
    /// 因此按 display 缓存 contentFilter（排除全部窗口），屏幕配置变化时失效重建。
    private static let filterCacheLock = NSLock()
    private static var filterCache: [CGDirectDisplayID: SCContentFilter] = [:]

    static func invalidateFilterCache() {
        filterCacheLock.lock()
        filterCache.removeAll()
        filterCacheLock.unlock()
    }

    /// 取屏幕对应的 contentFilter：缓存命中直接复用，未命中才枚举 SCShareableContent
    private static func contentFilter(for displayID: CGDirectDisplayID) async -> SCContentFilter? {
        filterCacheLock.lock()
        if let cached = filterCache[displayID] {
            filterCacheLock.unlock()
            return cached
        }
        filterCacheLock.unlock()

        do {
            let content = try await SCShareableContent.current
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                ZSLog("no SC display for id \(displayID)")
                return nil
            }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            filterCacheLock.lock()
            filterCache[displayID] = filter
            filterCacheLock.unlock()
            return filter
        } catch {
            ZSLog("SCShareableContent error: \(error)")
            return nil
        }
    }
}