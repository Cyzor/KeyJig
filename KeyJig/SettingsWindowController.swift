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

        // Wire up content before measuring so the SwiftUI layout engine
        // has a valid hosting context to work with.
        let hostingController = NSHostingController(rootView: SettingsView(appState: appState))
        window.contentViewController = hostingController

        // Pin the view width so the layout engine word-wraps text at the
        // correct width before we ask for the fitting height.
        hostingController.view.frame.size.width = 460
        hostingController.view.layoutSubtreeIfNeeded()
        let fit = hostingController.view.fittingSize

        // Floor values guard against pathological zero measurements.
        let minContent = NSSize(width: max(fit.width, 440), height: max(fit.height, 520))

        // Set the minimum BEFORE restoring the autosaved frame so AppKit
        // clamps any persisted size that is smaller than the content requires.
        window.contentMinSize = minContent

        let didRestore = window.setFrameUsingName("SettingsWindow")
        if !didRestore {
            window.setContentSize(minContent)
            window.center()
        } else {
            // Explicitly enforce the minimum in case the persisted frame
            // predates the contentMinSize requirement being set here.
            let saved = window.contentRect(forFrameRect: window.frame).size
            if saved.width < minContent.width || saved.height < minContent.height {
                window.setContentSize(minContent)
                window.center()
            }
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
