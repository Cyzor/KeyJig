import Cocoa
import SwiftUI
import WebKit

// MARK: - Main Window Controller

class MainWindowController: NSWindowController, NSWindowDelegate {

    /// Each window owns its own state — changes in one window never affect another.
    let appState: AppState

    init(appState: AppState = AppState(), isPrimary: Bool = false) {
        self.appState = appState

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.title = "Vector Importer"
        window.minSize = NSSize(width: 320, height: 380)
        window.maxSize = NSSize(width: 900, height: 1200)

        super.init(window: window)

        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: ContentView(appState: appState))

        if isPrimary {
            // Setting the autosave name AFTER super.init means AppKit can
            // actually find and restore the previously saved frame.
            // If no saved frame exists yet, centre the window.
            let didRestore = window.setFrameUsingName("VectorImporterMainWindow")
            if !didRestore { window.center() }
            window.setFrameAutosaveName("VectorImporterMainWindow")
        } else {
            // Secondary windows cascade; they don't clobber the primary's saved frame.
            window.center()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        AppDelegate.shared?.floatingWindows.removeAll { $0 === self }
    }
}

// MARK: - App Menu

class AppMenu {
    static func setupMenuBar() {
        let mainMenu = NSMenu()

        // ── Apple / App menu ──────────────────────────────────────────────
        let appMenuItem = mainMenu.addItem(
            withTitle: "VectorImporter", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "VectorImporter")
        appMenu.addItem(
            withTitle: "About VectorImporter",
            action: #selector(AppDelegate.showAbout),
            keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Hide VectorImporter",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "")
        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit VectorImporter",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // ── File menu ─────────────────────────────────────────────────────
        let fileMenuItem = mainMenu.addItem(
            withTitle: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(
            withTitle: "Show Window",
            action: #selector(AppDelegate.showMainWindow),
            keyEquivalent: "n")
        fileMenu.addItem(
            withTitle: "New Viewer",
            action: #selector(AppDelegate.newFloatingWindow),
            keyEquivalent: "N"
        ).keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(
            withTitle: "Open SVG File…",
            action: #selector(AppDelegate.openSVGFile),
            keyEquivalent: "o")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu

        // ── Edit menu ─────────────────────────────────────────────────────
        let editMenuItem = mainMenu.addItem(
            withTitle: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: nil, keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: nil, keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: nil, keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: nil, keyEquivalent: "v")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(
            withTitle: "Clear",
            action: #selector(AppDelegate.clearSVG),
            keyEquivalent: "")
        editMenuItem.submenu = editMenu

        // ── Help menu ─────────────────────────────────────────────────────
        let helpMenuItem = mainMenu.addItem(
            withTitle: "Help", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(
            withTitle: "VectorImporter Help",
            action: #selector(AppDelegate.showHelp),
            keyEquivalent: "?")
        helpMenuItem.submenu = helpMenu

        NSApplication.shared.mainMenu = mainMenu
    }
}

// MARK: - AppDelegate

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    static var shared: AppDelegate?

    /// The primary window — its frame position is persisted across launches.
    var primaryWindowController: MainWindowController?

    /// All open windows, including the primary.
    var floatingWindows: [MainWindowController] = []

    /// Status-bar item — secondary shortcut to surface the app.
    var statusBarItem: NSStatusItem?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        AppDelegate.shared = self
        NSApplication.shared.delegate = self

        AppMenu.setupMenuBar()

        // ── Status bar ────────────────────────────────────────────────────
        statusBarItem = NSStatusBar.system.statusItem(
            withLength: CGFloat(NSStatusItem.variableLength))
        if let button = statusBarItem?.button {
            if let icon = NSImage(named: "Icon") {
                icon.size = NSSize(width: 18, height: 18)
                icon.isTemplate = true
                button.image = icon
            }
            button.action = #selector(showMainWindow)
            button.target = self
        }

        // ── Primary floating window ───────────────────────────────────────
        let wc = MainWindowController(isPrimary: true)
        primaryWindowController = wc
        floatingWindows.append(wc)

        // Seed the primary window's state from the clipboard if SVG is present.
        checkAndLoadClipboardSVG(into: wc.appState)

        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Clipboard helper

    /// Pushes clipboard SVG content into `state` only if the clipboard has
    /// something new — avoids stomping content the user loaded via file/drop.
    private func checkAndLoadClipboardSVG(into state: AppState) {
        let svg = convertClipboardToSVG()
        if !svg.isEmpty, svg != state.svgString {
            state.svgString = svg
        }
    }

    /// Resolves the AppState for the most appropriate window to receive
    /// clipboard content or menu actions.
    ///
    /// Priority:
    ///   1. A window in our floatingWindows list that is currently key.
    ///   2. NSApp.keyWindow if it belongs to one of our controllers (covers
    ///      the brief window between activation and key-window assignment).
    ///   3. The primary window as the final fallback.
    private var frontWindowState: AppState? {
        if let wc = floatingWindows.first(where: { $0.window?.isKeyWindow == true }) {
            return wc.appState
        }
        if let keyWin = NSApp.keyWindow,
            let wc = floatingWindows.first(where: { $0.window === keyWin })
        {
            return wc.appState
        }
        return primaryWindowController?.appState
    }

    // MARK: Actions

    /// Brings the primary window to the front, recreating it if it was closed,
    /// and seeds it with whatever is currently on the clipboard.
    @objc func showMainWindow() {
        let wc: MainWindowController
        if let existing = primaryWindowController, existing.window != nil {
            wc = existing
        } else {
            let fresh = MainWindowController(isPrimary: true)
            primaryWindowController = fresh
            floatingWindows.append(fresh)
            wc = fresh
        }
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Seed after activation so the window is visible when content appears.
        checkAndLoadClipboardSVG(into: wc.appState)
    }

    /// Opens a new independent viewer window (File > New Viewer / ⌘⇧N).
    /// Each extra window starts empty; it has no saved frame position of its own.
    @objc func newFloatingWindow() {
        let wc = MainWindowController(isPrimary: false)

        // Cascade relative to the most recently opened window.
        if let last = floatingWindows.last?.window?.frame {
            wc.window?.setFrameOrigin(
                CGPoint(x: last.origin.x + 20, y: last.origin.y - 20))
        }

        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        floatingWindows.append(wc)
    }

    /// Opens an SVG file into whichever window is currently key.
    /// Falls back to the primary window if no key window can be found.
    @objc func openSVGFile() {
        let dialog = NSOpenPanel()
        dialog.title = "Choose a .svg file"
        dialog.showsHiddenFiles = false
        dialog.canChooseDirectories = false
        dialog.allowsMultipleSelection = false
        dialog.allowedFileTypes = ["svg"]

        guard dialog.runModal() == .OK, let url = dialog.url else { return }

        let target = frontWindowState
        guard let state = target else { return }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            state.svgURL = url.path
            state.svgString = content
        } catch {
            NSLog("VectorImporter: error reading file: \(error)")
        }
    }

    /// Clears the content of whichever window is currently key.
    @objc func clearSVG() {
        frontWindowState?.svgString = ""
        frontWindowState?.svgURL = ""
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Vector Importer"
        alert.informativeText = """
            A utility for converting vector graphics to Keynote-compatible formats.

            Version 1.1

            Copyright © 2021 Jonathan Lampérth

            The Noun Project licensed under CC-BY-3.0 US:
            https://thenounproject.com/legal/terms-of-use/#icon-licenses
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Noted")
        alert.runModal()
    }

    @objc func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Help"
        alert.informativeText = """
            Vector Importer helps you convert and import vector graphics into Keynote.

            • Copy artwork in Illustrator / Affinity Designer / Inkscape (⌘C).
            • VectorImporter detects the SVG on your clipboard automatically.
            • Press "Copy to Clipboard" to re-encode it for Keynote.
            • Switch to Keynote and paste (⌘V).

            You can also drag an SVG file onto the preview well, or use
            File > Open SVG File… to browse for one.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: NSApplicationDelegate

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        // Keep running so the status-bar item stays active.
        return false
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        // On reactivation (e.g. switching back from Illustrator), seed the
        // front window. frontWindowState falls back to the primary window so
        // this never silently does nothing even if key-window state hasn't
        // transferred yet.
        if let state = frontWindowState {
            checkAndLoadClipboardSVG(into: state)
        }
    }

    // MARK: Dock menu

    @objc func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Show Window",
            action: #selector(showMainWindow),
            keyEquivalent: "")
        menu.addItem(
            withTitle: "New Viewer",
            action: #selector(newFloatingWindow),
            keyEquivalent: "")
        return menu
    }
}
