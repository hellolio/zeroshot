import Foundation

/// 幽灵窗口判定（对齐 AltTab `PhantomWindowDetector.cgsVerdict`，去掉 tab/isFocused 分支）。
///
/// 「幽灵窗口」= macOS API（AX/CGWindowList）还能给出、但 app 并不真正展示给用户的窗口：
/// alpha=0 的 Outlook 提醒、`orderOut:`/`show:false` 的 Electron 窗口、微信/Teams 隐藏窗口、
/// 以及 WindowServer 为真实窗口伴生的影子记录（Chrome/微信 里的空卡）。像素内容是空/黑/无所谓，
/// 判定的依据是 CGS 的两个正交事实：窗口是否在「可见列表」里（非 invisible 标签）、
/// 是否在「全量列表」里（含 invisible 标签）、窗口属于哪些 Space、当前可见 Space 集合。
///
/// 判定顺序（首条命中即返回）：
///   1. 最小化 / 隐藏 app 的窗口 → 非幽灵（CGS 可能不把它们列进任何 Space，先豁免防误伤）；
///   2. wid 不在全量列表 → 幽灵（强信号：CGS 已从所有 Space 追踪里清除）；
///   3. wid 在可见列表 → 非幽灵（正在渲染）；
///   4. 已知 Space 且与当前可见 Space 无交集 → 非幽灵（其他 Space 的真实窗口）；
///   5. 否则 → 幽灵（弱信号：在当前可见 Space 上却被标为 invisible，即 alpha=0 / orderOut）。
enum PhantomWindowDetector {
    static func isPhantom(minimized: Bool,
                          appHidden: Bool,
                          inVisibleList: Bool,
                          inAllList: Bool,
                          spaceIds: [UInt64],
                          visibleSpaceIds: [UInt64]) -> Bool {
        if minimized || appHidden { return false }
        if !inAllList { return true }
        if inVisibleList { return false }
        if !visibleSpaceIds.isEmpty,
           !spaceIds.isEmpty,
           !spaceIds.contains(where: { visibleSpaceIds.contains($0) }) {
            return false
        }
        return true
    }
}
