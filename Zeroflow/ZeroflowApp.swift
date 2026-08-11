import SwiftUI
import AppKit

@main
struct ZeroflowMain {
    static func main() {
        let app = NSApplication.shared
        let controller = MenuBarController()
        app.delegate = controller
        app.run()
    }
}

#Preview {
    SettingsView()
}