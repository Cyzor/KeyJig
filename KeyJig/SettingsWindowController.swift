import AppKit
import SwiftUI

class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let appState: AppState

    init(appState: AppState) {
        self.appState = appState

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = NSLocalizedString(
            "settings.window.title",
            comment: "Settings window title")
        window.isReleasedWhenClosed = false

        // Centre the window on the main screen, or restore saved position
        let didRestore = window.setFrameUsingName("SettingsWindow")
        if !didRestore {
            window.center()
        }
        window.setFrameAutosaveName("SettingsWindow")

        let settingsView = SettingsView(appState: appState)
        window.contentViewController = NSHostingController(rootView: settingsView)

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
