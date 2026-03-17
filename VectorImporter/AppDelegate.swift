import Cocoa
import Combine
import SwiftUI
import WebKit

// MARK: - Main Window Controller

class MainWindowController: NSWindowController, NSWindowDelegate {

    /// Each window owns its own state — changes in one window never affect another.
    let appState: AppState

    /// Retains the Combine subscription that keeps the proxy icon current.
    private var representedURLCancellable: AnyCancellable?

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

        // Enable the proxy icon. representedURL will be kept current below.
        window.isExcludedFromWindowsMenu = false

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

        // Subscribe to AppState changes and update the proxy icon accordingly.
        // Priority order:
        //   1. Temp bridge file — exists once svgToClipboard() or an outbound
        //      drag has run, i.e. the file Keynote actually consumed.
        //   2. Source file — set when the SVG was opened from disk or dropped.
        //   3. nil — well is empty; clears the proxy icon.
        representedURLCancellable = appState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // objectWillChange fires before the value changes, so we
                // defer by one run-loop turn to read the new value.
                DispatchQueue.main.async { self?.updateRepresentedURL() }
            }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: Proxy icon

    /// Resolves and applies the most meaningful file URL to the window's proxy icon.
    func updateRepresentedURL() {
        guard !appState.svgString.isEmpty else {
            // Well is empty — remove proxy icon.
            window?.representedURL = nil
            window?.title = "Vector Importer"
            return
        }

        // Prefer the temp bridge file (the converted output Keynote consumed).
        // We read it from appState.bridgeFileURL rather than recomputing a
        // name, because the name is now randomised per write.
        if let bridgeURL = appState.bridgeFileURL,
            FileManager.default.fileExists(atPath: bridgeURL.path)
        {
            window?.representedURL = bridgeURL
            window?.title = bridgeURL.deletingPathExtension().lastPathComponent
            return
        }

        // Fall back to the original source file if one is known.
        if !appState.svgURL.isEmpty {
            let sourceURL = URL(fileURLWithPath: appState.svgURL)
            window?.representedURL = sourceURL
            window?.title = sourceURL.deletingPathExtension().lastPathComponent
            return
        }

        // SVG came from the clipboard — no file to represent yet.
        window?.representedURL = nil
        window?.title = "Vector Importer"
    }

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
            withTitle: "Preferences…",
            action: #selector(AppDelegate.openPreferences),
            keyEquivalent: ",")
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
            withTitle: "Show Menubar Panel",
            action: #selector(AppDelegate.togglePopover),
            keyEquivalent: "n")
        fileMenu.addItem(
            withTitle: "Show Window",
            action: #selector(AppDelegate.showMainWindow),
            keyEquivalent: "")
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

    /// Status-bar item — click toggles the menubar popover.
    var statusBarItem: NSStatusItem?

    /// The menubar popover and its own independent AppState.
    var popover: NSPopover?
    var popoverAppState: AppState = AppState()

    /// Settings window controller (created lazily when user opens preferences).
    var settingsWindowController: SettingsWindowController?

    // MARK: Scriptable properties for Explorer visibility

    /// Returns the SVG content from the frontmost window.
    @objc dynamic var scriptingSVG: String {
        return frontWindowState?.svgString ?? ""
    }

    /// Returns the file path of the SVG in the frontmost window.
    @objc dynamic var scriptingSVGFilePath: String {
        return frontWindowState?.svgURL ?? ""
    }

    /// Returns the width of the SVG in the frontmost window as text.
    @objc dynamic var scriptingSVGWidth: String {
        guard let svg = frontWindowState?.svgString, !svg.isEmpty else { return "" }
        guard let dims = extractSVGDimensions(svgString: svg) else { return "" }
        return dims.width
    }

    /// Returns the height of the SVG in the frontmost window as text.
    @objc dynamic var scriptingSVGHeight: String {
        guard let svg = frontWindowState?.svgString, !svg.isEmpty else { return "" }
        guard let dims = extractSVGDimensions(svgString: svg) else { return "" }
        return dims.height
    }

    /// Returns the file size of the SVG in the frontmost window as a formatted string.
    @objc dynamic var scriptingFileSize: String {
        guard let svg = frontWindowState?.svgString else { return "" }
        return getFileSizeString(svgString: svg)
    }

    /// Returns the creator metadata from the SVG in the frontmost window.
    @objc dynamic var scriptingSVGCreator: String {
        guard let svg = frontWindowState?.svgString, !svg.isEmpty else { return "" }
        return extractSVGCreator(svgString: svg) ?? ""
    }

    /// Returns the document name (filename without extension) for the frontmost window.
    @objc dynamic var scriptingDocumentName: String {
        guard let state = frontWindowState, !state.svgString.isEmpty else { return "" }
        if !state.svgURL.isEmpty {
            return URL(fileURLWithPath: state.svgURL).deletingPathExtension().lastPathComponent
        }
        if let bridgeURL = state.bridgeFileURL {
            return bridgeURL.deletingPathExtension().lastPathComponent
        }
        return ""
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        AppDelegate.shared = self
        NSApplication.shared.delegate = self

        AppMenu.setupMenuBar()

        // ── Menubar popover ───────────────────────────────────────────────
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: ContentView(appState: popoverAppState))
        popover.behavior = .transient
        self.popover = popover

        // ── Status bar ────────────────────────────────────────────────────
        statusBarItem = NSStatusBar.system.statusItem(
            withLength: CGFloat(NSStatusItem.variableLength))
        if let button = statusBarItem?.button {
            if let icon = NSImage(named: "Icon") {
                icon.size = NSSize(width: 18, height: 18)
                icon.isTemplate = true
                button.image = icon
            }
            button.action = #selector(togglePopover)
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
    ///
    /// Fast path: checks for native SVG types synchronously.
    /// Slow path: if no SVG is found but PDF/AICB is present and Inkscape is
    /// installed, converts asynchronously and updates state on completion.
    private func checkAndLoadClipboardSVG(into state: AppState) {
        // Fast path — native SVG, completes instantly.
        let svg = convertClipboardToSVG()
        if !svg.isEmpty, svg != state.svgString {
            state.svgString = svg
            return
        }

        // Slow path — only attempt if the window is empty, there is convertible
        // data on the clipboard, and Inkscape is actually installed.
        guard state.svgString.isEmpty,
            clipboardHasConvertibleVectorData(),
            inkscapeURL() != nil
        else { return }

        state.conversionStatus = .converting
        convertClipboardPDFToSVG { [weak state] result in
            guard let state = state else { return }
            if let svg = result, !svg.isEmpty {
                state.svgString = svg
                state.conversionStatus = .idle
            } else {
                state.conversionStatus = .failed
            }
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

    /// Toggles the menubar popover, seeding it from the clipboard when opening.
    @objc func togglePopover() {
        guard let popover = self.popover,
            let button = statusBarItem?.button
        else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            checkAndLoadClipboardSVG(into: popoverAppState)
            popover.show(
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .minY)
        }
    }

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

    /// Opens a vector file into whichever window is currently key.
    /// Falls back to the primary window if no key window can be found.
    /// Accepts SVG directly; converts PDF and AI via Inkscape when available.
    @objc func openSVGFile() {
        let dialog = NSOpenPanel()
        dialog.title = "Choose a vector file"
        dialog.showsHiddenFiles = false
        dialog.canChooseDirectories = false
        dialog.allowsMultipleSelection = false

        var types = ["svg"]
        if inkscapeURL() != nil {
            types += ["pdf", "ai"]
        }
        dialog.allowedFileTypes = types

        guard dialog.runModal() == .OK, let url = dialog.url else { return }

        let target = frontWindowState
        guard let state = target else { return }

        let ext = url.pathExtension.lowercased()

        if ext == "svg" {
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                state.svgURL = url.path
                state.svgString = content
            } catch {
                NSLog("VectorImporter: error reading file: \(error)")
            }
            return
        }

        if ext == "pdf" || ext == "ai" {
            state.conversionStatus = .converting
            DispatchQueue.global(qos: .userInitiated).async {
                let svg = convertFileToSVGWithInkscape(url: url)
                DispatchQueue.main.async {
                    if let svg = svg, !svg.isEmpty {
                        state.svgURL = url.path
                        state.svgString = svg
                        state.conversionStatus = .idle
                    } else {
                        state.conversionStatus = .failed
                    }
                }
            }
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

    @objc func openPreferences() {
        if settingsWindowController == nil {
            // Use the primary window's AppState, or create a default one
            let appState = primaryWindowController?.appState ?? AppState()
            settingsWindowController = SettingsWindowController(appState: appState)
        }
        settingsWindowController?.showWindow()
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
        // Also seed the popover if it happens to be open.
        if popover?.isShown == true {
            checkAndLoadClipboardSVG(into: popoverAppState)
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

// MARK: - Settings Window Controller

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

        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.setFrameUsingName("SettingsWindow")

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
