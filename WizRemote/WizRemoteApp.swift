import AppKit
import SwiftUI

@main
struct WizRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            if let window = NSApplication.shared.windows.first {
                let size = NSSize(width: 760, height: 620)
                window.setContentSize(size)
                window.center()
                window.title = "WiZ Remote"
                window.styleMask.insert(.resizable)
            }
        }
    }
}
