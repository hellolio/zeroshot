import SwiftUI
import AppKit

/// 辅助功能权限状态与引导（公共组件）。
/// 由 Dock 标签页的 `DockPermissionRow` 抽出，Dock 与「切换」标签页共用，避免两套实现漂移。
struct AccessibilityPermissionRow: View {
    /// 未授权时的原因文案（Dock 用「需要「辅助功能」权限才能最小化窗口」等）
    let message: String

    @State private var granted = AccessibilityPermission.isGranted

    var body: some View {
        Group {
            if granted {
                Label(L10n.tr("辅助功能权限已开启"), systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    HStack(spacing: 12) {
                        Button(L10n.tr("打开系统设置授权")) {
                            AccessibilityPermission.requestAuthorization()
                        }
                        Button(L10n.tr("重新检测")) {
                            granted = AccessibilityPermission.isGranted
                        }
                    }
                }
            }
        }
        // 授权后回到应用自动重查
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            granted = AccessibilityPermission.isGranted
        }
    }
}