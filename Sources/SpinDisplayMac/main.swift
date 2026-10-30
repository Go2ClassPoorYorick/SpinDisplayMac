import AppKit
import SwiftUI

@main
struct SpinDisplayMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .help) {
                // The original app shipped a manufacturer manual (help.pdf). It is copyrighted, so it is only
                // bundled from a local copy; otherwise this opens the manufacturer's SpinDisplay page.
                Button("SpinDisplay Manual") {
                    if let url = Bundle.main.url(forResource: "help", withExtension: "pdf") {
                        NSWorkspace.shared.open(url)
                    } else if let url = URL(string: "https://www.ftlled.com/spindisplay") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut("?", modifiers: .command)
            }
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
