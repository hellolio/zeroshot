import AppKit
import CoreGraphics
import Darwin

/// 窗口缩略图抓取：SkyLight 私有 API `CGSHWCaptureWindowList`（运行时 dlsym 桥接）。
/// - 能截取最小化/离屏窗口（公开 API ScreenCaptureKit 截不到最小化窗口）。
/// - 全程后台单队列执行，逐窗口调用（该 API 实际只认窗口列表第一个，批量传会丢结果）。
/// - 按 CGWindowID 缓存（会话间 TTL ≈ 5s）；同一窗口 800ms 内不重复抓。
/// - 抓取失败/API 缺失时静默降级（面板显示 app 图标），不弹错不崩溃。
final class WindowThumbnailer {
    static let shared = WindowThumbnailer()

    private let queue = DispatchQueue(label: "zeroflow.window-thumbnailer", qos: .userInitiated)
    private let lock = NSLock()
    private var cache: [CGWindowID: (image: NSImage, date: Date)] = [:]
    private var lastAttempt: [CGWindowID: Date] = [:]
    private static var didLogBridgeFailure = false

    // AltTab 实际使用的选项位（旧版头文件的 0x04|0x10|0x20 已失效，传 0x34 会返回空）：
    // ignoreGlobalClipShape=1<<11, bestResolution=1<<8, fullSize=1<<19
    private static let captureOptions: Int32 = (1 << 11) | (1 << 8) | (1 << 19)
    private let cacheTTL: TimeInterval = 5
    private let captureThrottle: TimeInterval = 0.8
    private static let maxThumbSide: CGFloat = 320
    /// 缩略图缓存上限：超出时淘汰最旧的（内存有界，长时间运行不会无限增长）
    private static let maxCacheCount = 30

    private struct CaptureBridge {
        let mainConn: @convention(c) () -> Int32
        let captureList: @convention(c) (Int32, UnsafeMutablePointer<CGWindowID>, Int32, Int32) -> Unmanaged<CFArray>?
    }

    private static let bridge: CaptureBridge? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else {
            ZSLog("WindowThumbnailer: dlopen SkyLight failed — thumbnails will fall back to app icons")
            return nil
        }
        guard let connSym = dlsym(handle, "CGSMainConnectionID"),
              let captureSym = dlsym(handle, "CGSHWCaptureWindowList") else {
            ZSLog("WindowThumbnailer: SkyLight symbol missing — thumbnails will fall back to app icons")
            return nil
        }
        let mainConn = unsafeBitCast(connSym, to: (@convention(c) () -> Int32).self)
        let captureList = unsafeBitCast(captureSym, to: (@convention(c) (Int32, UnsafeMutablePointer<CGWindowID>, Int32, Int32) -> Unmanaged<CFArray>?).self)
        return CaptureBridge(mainConn: mainConn, captureList: captureList)
    }()

    func invalidateCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    /// 后台抓取一批窗口缩略图，完成后在主队列回调 `[CGWindowID: NSImage]`（只含抓到的）。
    func fetchThumbnails(for windows: [SwitcherWindow],
                         completion: @escaping ([CGWindowID: NSImage]) -> Void) {
        queue.async { [self] in
            let result = captureAll(windows: windows)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private func captureAll(windows: [SwitcherWindow]) -> [CGWindowID: NSImage] {
        guard let bridge = Self.bridge else {
            if !Self.didLogBridgeFailure {
                Self.didLogBridgeFailure = true
                ZSLog("WindowThumbnailer: SkyLight unavailable, logging once and downgrading to icons")
            }
            return [:]
        }
        let now = Date()
        var out: [CGWindowID: NSImage] = [:]
        var missing: [CGWindowID] = []

        lock.lock()
        for w in windows {
            if let entry = cache[w.id], now.timeIntervalSince(entry.date) < cacheTTL {
                out[w.id] = entry.image
            } else if let last = lastAttempt[w.id], now.timeIntervalSince(last) < captureThrottle {
                // 节流：不在短时间内重复抓同一窗口
            } else {
                lastAttempt[w.id] = now
                missing.append(w.id)
            }
        }
        lock.unlock()

        guard !missing.isEmpty else { return out }

        let boundsMap = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.bounds) })
        let captured = capture(wids: missing, boundsMap: boundsMap, bridge: bridge)
        lock.lock()
        for (wid, image) in captured {
            guard let image else { continue }
            let size = boundsMap[wid] ?? CGRect(x: 0, y: 0, width: 16, height: 10)
            let thumb = resized(image, bounds: size)
            cache[wid] = (thumb, now)
            out[wid] = thumb
        }
        pruneCache(now: now)
        lock.unlock()
        return out
    }

    /// 钳制缓存内存：清掉超过 TTL 的过期条目（下次会话反正要重新抓），
    /// 再超过数量上限时淘汰最旧的，保证长时间运行下缓存有界。
    /// 节流表 `lastAttempt` 同样只增不删，一并按 TTL 清理。
    private func pruneCache(now: Date) {
        cache = cache.filter { now.timeIntervalSince($0.value.date) < cacheTTL }
        lastAttempt = lastAttempt.filter { now.timeIntervalSince($0.value) < cacheTTL }
        if cache.count > Self.maxCacheCount {
            let byNewest = cache.sorted { $0.value.date > $1.value.date }
            cache = Dictionary(uniqueKeysWithValues: byNewest.prefix(Self.maxCacheCount).map { ($0.key, $0.value) })
        }
    }

    /// 逐窗口调用私有 API，返回 `[CGWindowID: CGImage?]`。
    /// 该 API 只认窗口列表里的第一个（AltTab 源码注释），批量传会丢其余窗口，故逐窗口调用。
    private func capture(wids: [CGWindowID],
                         boundsMap: [CGWindowID: CGRect],
                         bridge: CaptureBridge) -> [CGWindowID: CGImage?] {
        var result: [CGWindowID: CGImage?] = [:]
        let cid = bridge.mainConn()
        for wid in wids {
            var id = wid
            if let array = bridge.captureList(cid, &id, 1, Self.captureOptions)?.takeRetainedValue() as? [CGImage],
               let image = array.first {
                result[wid] = image
            }
        }
        return result
    }

    /// 按窗口宽高比把原始 CGImage 缩放到缩略图尺寸（2x 物理像素，控制驻留内存）
    private func resized(_ image: CGImage, bounds: CGRect) -> NSImage {
        let aspect = bounds.width > 0 && bounds.height > 0 ? bounds.height / bounds.width : 10.0 / 16.0
        var w = Self.maxThumbSide
        var h = Self.maxThumbSide * aspect
        if h > Self.maxThumbSide {
            h = Self.maxThumbSide
            w = Self.maxThumbSide / aspect
        }
        let pxW = max(1, Int(w * 2))
        let pxH = max(1, Int(h * 2))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return NSImage(cgImage: image, size: NSSize(width: w, height: h))
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(pxW), height: CGFloat(pxH)))
        guard let out = ctx.makeImage() else {
            return NSImage(cgImage: image, size: NSSize(width: w, height: h))
        }
        return NSImage(cgImage: out, size: NSSize(width: w, height: h))
    }
}