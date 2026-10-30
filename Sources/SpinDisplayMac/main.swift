import AppKit
import SwiftUI

@main
struct SpinDisplayMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Quits when the main window closes. The projection capture frame is a borderless window, so it is
/// ignored when deciding whether any app window is still open.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var closeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { notification in
            guard let closing = notification.object as? NSWindow, closing.styleMask.contains(.titled) else { return }
            let remaining = NSApp.windows.filter { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
            if remaining.isEmpty { NSApp.terminate(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
