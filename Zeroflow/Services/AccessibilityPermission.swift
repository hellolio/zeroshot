import ApplicationServices

/// 辅助功能权限检测（Dock 单击最小化等依赖 AX 的能力）
enum AccessibilityPermission {
    static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// 弹出系统「辅助功能」授权窗口
    static func requestAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}