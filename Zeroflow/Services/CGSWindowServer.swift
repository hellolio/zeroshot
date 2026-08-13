import AppKit
import CoreGraphics
import Darwin

/// SkyLight / CGS 私有 API 桥（运行时 dlsym，与 `WindowThumbnailer` 同款模式）。
/// - 枚举：`SLSWindowQueryWindows` 批量取 typed 字段（title/bounds/level/attributes/spaceTypeMask/tags）。
/// - 成员：`CGSCopyWindowsWithOptionsAndTags`（`.invisible1/.invisible2` 区分「可见列表」与「全量列表」）。
/// - Space：`CGSCopyManagedDisplaySpaces`（各屏当前 Space）+ 逐 Space 反查窗口归属。
/// 任一符号缺失 → `isAvailable == false`，调用方退回公开 API（CGWindowList），不崩。
/// 说明：本工程已在使用 SkyLight 私有 API（WindowThumbnailer），此处同样是 AltTab 的正式做法。
final class CGSWindowServer {
    static let shared = CGSWindowServer()

    /// SLS 批量查询返回的一个窗口的 typed 字段
    struct RawWindow {
        let wid: CGWindowID
        let pid: pid_t
        let title: String
        let bounds: CGRect
        let level: Int32
        let attributes: UInt64
        let spaceTypeMask: UInt64
        let tags: UInt64
    }

    // MARK: - dlsym 函数类型

    private typealias MainConnFn = @convention(c) () -> UInt32
    private typealias CopyWindowsFn = @convention(c) (UInt32, Int, CFArray, Int, UnsafeMutablePointer<Int>, UnsafeMutablePointer<Int>) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (UInt32, Int, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    private typealias QueryWindowsFn = @convention(c) (UInt32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
    private typealias QueryResultFn = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    private typealias IterAdvanceFn = @convention(c) (CFTypeRef) -> Bool
    private typealias IterGetU32Fn = @convention(c) (CFTypeRef) -> UInt32
    private typealias IterGetPidFn = @convention(c) (CFTypeRef) -> pid_t
    private typealias IterGetI32Fn = @convention(c) (CFTypeRef) -> Int32
    private typealias IterGetU64Fn = @convention(c) (CFTypeRef) -> UInt64
    private typealias IterCopyTitleFn = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?
    private typealias IterGetBoundsFn = @convention(c) (UnsafeRawPointer) -> CGRect

    private struct Bridge {
        let mainConn: MainConnFn
        let copyWindows: CopyWindowsFn
        let copySpacesForWindows: CopySpacesForWindowsFn
        let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn
        let queryWindows: QueryWindowsFn
        let queryResult: QueryResultFn
        let iterAdvance: IterAdvanceFn
        let iterGetWindowID: IterGetU32Fn
        let iterGetPID: IterGetPidFn
        let iterGetLevel: IterGetI32Fn
        let iterGetSpaceTypeMask: IterGetU64Fn
        let iterGetTags: IterGetU64Fn
        let iterGetAttributes: IterGetU64Fn
        let iterCopyTitle: IterCopyTitleFn
        let iterGetBounds: IterGetBoundsFn
    }

    private let bridge: Bridge?
    private let cid: UInt32
    var isAvailable: Bool { bridge != nil }

    private init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else {
            ZSLog("CGSWindowServer: dlopen SkyLight failed, falling back to public API")
            bridge = nil
            cid = 0
            return
        }
        // 不 dlclose：函数指针由 SkyLight 提供，系统常驻，避免卸载风险
        if let loaded = Self.loadBridge(from: handle) {
            bridge = loaded.bridge
            cid = loaded.cid
        } else {
            ZSLog("CGSWindowServer: symbols missing, falling back to public API")
            bridge = nil
            cid = 0
        }
    }

    private static func loadBridge(from handle: UnsafeMutableRawPointer) -> (cid: UInt32, bridge: Bridge)? {
        func sym<T>(_ name: String) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let mainConn: MainConnFn = sym("CGSMainConnectionID"),
              let copyWindows: CopyWindowsFn = sym("CGSCopyWindowsWithOptionsAndTags"),
              let copySpacesForWindows: CopySpacesForWindowsFn = sym("CGSCopySpacesForWindows"),
              let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn = sym("CGSCopyManagedDisplaySpaces"),
              let queryWindows: QueryWindowsFn = sym("SLSWindowQueryWindows"),
              let queryResult: QueryResultFn = sym("SLSWindowQueryResultCopyWindows"),
              let iterAdvance: IterAdvanceFn = sym("SLSWindowIteratorAdvance"),
              let iterGetWindowID: IterGetU32Fn = sym("SLSWindowIteratorGetWindowID"),
              let iterGetPID: IterGetPidFn = sym("SLSWindowIteratorGetPID"),
              let iterGetLevel: IterGetI32Fn = sym("SLSWindowIteratorGetLevel"),
              let iterGetSpaceTypeMask: IterGetU64Fn = sym("SLSWindowIteratorGetSpaceTypeMask"),
              let iterGetTags: IterGetU64Fn = sym("SLSWindowIteratorGetTags"),
              let iterGetAttributes: IterGetU64Fn = sym("SLSWindowIteratorGetAttributes"),
              let iterCopyTitle: IterCopyTitleFn = sym("SLSWindowIteratorCopyTitle"),
              let iterGetBounds: IterGetBoundsFn = sym("SLSWindowIteratorGetBounds")
        else { return nil }
        let bridge = Bridge(mainConn: mainConn, copyWindows: copyWindows, copySpacesForWindows: copySpacesForWindows,
                            copyManagedDisplaySpaces: copyManagedDisplaySpaces, queryWindows: queryWindows,
                            queryResult: queryResult, iterAdvance: iterAdvance, iterGetWindowID: iterGetWindowID,
                            iterGetPID: iterGetPID, iterGetLevel: iterGetLevel, iterGetSpaceTypeMask: iterGetSpaceTypeMask,
                            iterGetTags: iterGetTags, iterGetAttributes: iterGetAttributes,
                            iterCopyTitle: iterCopyTitle, iterGetBounds: iterGetBounds)
        return (mainConn(), bridge)
    }

    // MARK: - SLS 批量枚举

    /// 对 wids 批量查询 typed 字段（一次 IPC）。
    func queryWindows(_ wids: [CGWindowID]) -> [RawWindow] {
        guard let bridge, !wids.isEmpty else { return [] }
        guard let query = bridge.queryWindows(cid, wids as CFArray, Int32(wids.count))?.takeRetainedValue(),
              let iterator = bridge.queryResult(query)?.takeRetainedValue()
        else { return [] }
        var out: [RawWindow] = []
        while bridge.iterAdvance(iterator) {
            out.append(RawWindow(
                wid: bridge.iterGetWindowID(iterator),
                pid: bridge.iterGetPID(iterator),
                title: bridge.iterCopyTitle(iterator)?.takeRetainedValue() as String? ?? "",
                bounds: bridge.iterGetBounds(Unmanaged.passUnretained(iterator).toOpaque()),
                level: bridge.iterGetLevel(iterator),
                attributes: bridge.iterGetAttributes(iterator),
                spaceTypeMask: bridge.iterGetSpaceTypeMask(iterator),
                tags: bridge.iterGetTags(iterator)
            ))
        }
        return out
    }

    // MARK: - Space 拓扑

    /// 所有 Space id（来自 CGSCopyManagedDisplaySpaces 的 Spaces[id64]）。
    func allSpaceIds() -> [UInt64] {
        guard let bridge else { return [] }
        guard let raw = bridge.copyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var ids = Set<UInt64>()
        for display in raw {
            if let spaces = display["Spaces"] as? [[String: Any]] {
                for space in spaces {
                    if let id64 = (space["id64"] as? NSNumber)?.uint64Value { ids.insert(id64) }
                }
            }
        }
        return Array(ids)
    }

    /// 当前可见 Space id（每屏一个，来自各屏的 Current Space）。
    func visibleSpaceIds() -> [UInt64] {
        guard let bridge else { return [] }
        guard let raw = bridge.copyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var ids: [UInt64] = []
        for display in raw {
            if let current = display["Current Space"] as? [String: Any],
               let id64 = (current["id64"] as? NSNumber)?.uint64Value {
                ids.append(id64)
            }
        }
        return ids
    }

    /// 指定 Space 上的窗口 id 列表。
    /// `includeInvisible=false` 排除 `.invisible1/.invisible2` 标签窗口（= 可见列表）；
    /// `includeInvisible=true` 含它们（= 全量列表）。
    func windowsInSpaces(_ spaceIds: [UInt64], includeInvisible: Bool) -> [CGWindowID] {
        guard let bridge, !spaceIds.isEmpty else { return [] }
        // 1<<0 = invisible1, 1<<2 = invisible2, 1<<1 = screenSaverLevel1000（AltTab 实测常量）
        let options = includeInvisible ? (1 << 0 | 1 << 1 | 1 << 2) : (1 << 1)
        var setTags = 0
        var clearTags = 0
        guard let array = bridge.copyWindows(cid, 0, spaceIds as CFArray, options, &setTags, &clearTags)?.takeRetainedValue() as? [CGWindowID] else { return [] }
        return array
    }
}
