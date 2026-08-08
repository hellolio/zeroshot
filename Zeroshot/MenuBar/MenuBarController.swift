import AppKit
import SwiftUI

/// 菜单栏控制器：常驻菜单栏，提供「设置」与「退出」
final class MenuBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    private var settingsWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()

        GlobalHotkeyManager.shared.setTriggerHandler {
            CaptureCoordinator.shared.startCapture()
        }
        GlobalHotkeyManager.shared.register(SettingsStore.shared.shortcut)

        if ProcessInfo.processInfo.environment["ZEROSHOT_AUTO_CAPTURE"] == "1" {
            ZSLog("env ZEROSHOT_AUTO_CAPTURE: defer 1.5s then capture")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                CaptureCoordinator.shared.startCapture()
            }
        }
        if ProcessInfo.processInfo.environment["ZEROSHOT_EDITOR_DEBUG"] == "1" {
            ZSLog("env ZEROSHOT_EDITOR_DEBUG: defer 1.5s then open editor directly")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                CaptureCoordinator.shared.openEditorForDebug()
            }
        }
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "camera.viewfinder",
            accessibilityDescription: "zeroshot"
        )
        item.button?.imagePosition = .imageOnly

        let menu = NSMenu()

        let captureItem = NSMenuItem(
            title: "立即截图（\(SettingsStore.shared.shortcut.displayString)）",
            action: #selector(startScreenshot), keyEquivalent: ""
        )
        captureItem.target = self
        menu.addItem(captureItem)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        if SettingsStore.shared.lastSavedPath != nil {
            let recentItem = NSMenuItem(title: "打开最近截图", action: #selector(openRecent), keyEquivalent: "")
            recentItem.target = self
            menu.addItem(recentItem)
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 zeroshot", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    @objc private func startScreenshot() {
        CaptureCoordinator.shared.startCapture()
    }

    @objc private func openRecent() {
        guard let path = SettingsStore.shared.lastSavedPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            let window = NSWindow(
                contentViewController: NSHostingController(rootView: SettingsView())
            )
            window.title = "zeroshot 设置"
            window.setContentSize(NSSize(width: 560, height: 480))
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}