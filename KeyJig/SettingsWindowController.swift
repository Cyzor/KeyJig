import AppKit
import SwiftUI

class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let appState: AppState

    init(appState: AppState) {
        self.appState = appState

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = NSLocalizedString(
            "settings.window.title",
            comment: "Settings window title")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.identifier = NSUserInterfaceItemIdentifier("SettingsWindow")

        // Wire up content before measuring so the SwiftUI layout engine
        // has a valid hosting context to work with.
        let hostingController = NSHostingController(rootView: SettingsView(appState: appState))
        // Prevent NSHostingController from resizing the window to its preferred
        // content size after the window is shown (macOS 13+). On older systems the
        // double-async explicit frame restore in AppDelegate handles the same race.
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = .minSize
        }
        window.contentViewController = hostingController

        // Pin the view width so the layout engine word-wraps text at the
        // correct width before we ask for the fitting height.
        hostingController.view.frame.size.width = 460
        hostingController.view.layoutSubtreeIfNeeded()
        let fit = hostingController.view.fittingSize

        // Floor values guard against pathological zero measurements.
        let minContent = NSSize(width: max(fit.width, 440), height: max(fit.height, 520))

        window.contentMinSize = minContent
        let didRestore = window.setFrameUsingName("SettingsWindow")
        if !didRestore {
            window.setContentSize(minContent)
            window.center()
        }
        window.setFrameAutosaveName("SettingsWindow")

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
