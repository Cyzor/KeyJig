import Cocoa
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import os

private let log = Logger(subsystem: "com.cyzor.KeyJig", category: "AppDelegate")

// MARK: - Main Window Controller

class MainWindowController: NSWindowController, NSWindowDelegate {

    /// Each window owns its own state — changes in one window never affect another.
    let appState: AppState

    /// Retains the Combine subscription that keeps the proxy icon current.
    private var representedURLCancellable: AnyCancellable?

    init(appState: AppState = AppState(), isPrimary: Bool = false) {
        self.appState = appState

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.title = NSLocalizedString(
            "window.title.default",
            comment: "Default window title when no file is loaded")
        window.minSize = NSSize(width: 320, height: 520)
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
            let didRestore = window.setFrameUsingName("KeyJigMainWindow")
            if !didRestore { window.center() }
            window.setFrameAutosaveName("KeyJigMainWindow")
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
            window?.title = NSLocalizedString(
                "window.title.default",
                comment: "Default window title when no file is loaded")
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
        window?.title = NSLocalizedString(
            "window.title.default",
            comment: "Default window title when no file is loaded")
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
            withTitle: "KeyJig", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "KeyJig")
        appMenu.addItem(
            withTitle: NSLocalizedString(
                "menu.app.about",
                comment: "App menu: About KeyJig item"),
            action: #selector(AppDelegate.showAbout),
            keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: NSLocalizedString(
                "menu.app.preferences",
                comment: "App menu: Preferences item"),
            action: #selector(AppDelegate.openPreferences),
            keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: NSLocalizedString(
                "menu.app.hide",
                comment: "App menu: Hide KeyJig item"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        appMenu.addItem(
            withTitle: NSLocalizedString(
                "menu.app.hide_others",
                comment: "App menu: Hide Others item"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "")
        appMenu.addItem(
            withTitle: NSLocalizedString(
                "menu.app.show_all",
                comment: "App menu: Show All item"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: NSLocalizedString(
                "menu.app.quit",
                comment: "App menu: Quit KeyJig item"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // ── File menu ─────────────────────────────────────────────────────
        let fileMenuItem = mainMenu.addItem(
            withTitle: NSLocalizedString("menu.file", comment: "File menu title"),
            action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: NSLocalizedString("menu.file", comment: "File menu title"))
        fileMenu.addItem(
            withTitle: NSLocalizedString(
                "menu.file.show_panel",
                comment: "File menu: Show Menubar Panel item"),
            action: #selector(AppDelegate.togglePopover),
            keyEquivalent: "n")
        fileMenu.addItem(
            withTitle: NSLocalizedString(
                "menu.file.show_window",
                comment: "File menu: Show Window item"),
            action: #selector(AppDelegate.showMainWindow),
            keyEquivalent: "")
        fileMenu.addItem(
            withTitle: NSLocalizedString(
                "menu.file.new_viewer",
                comment: "File menu: New Viewer item"),
            action: #selector(AppDelegate.newFloatingWindow),
            keyEquivalent: "N"
        ).keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(
            withTitle: NSLocalizedString(
                "menu.file.open_svg",
                comment: "File menu: Open SVG File item"),
            action: #selector(AppDelegate.openSVGFile),
            keyEquivalent: "o")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(
            withTitle: NSLocalizedString(
                "menu.file.close",
                comment: "File menu: Close item"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu

        // ── Edit menu ─────────────────────────────────────────────────────
        let editMenuItem = mainMenu.addItem(
            withTitle: NSLocalizedString("menu.edit", comment: "Edit menu title"),
            action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: NSLocalizedString("menu.edit", comment: "Edit menu title"))
        editMenu.addItem(
            withTitle: NSLocalizedString("menu.edit.undo", comment: "Edit menu: Undo"),
            action: nil, keyEquivalent: "z")
        editMenu.addItem(
            withTitle: NSLocalizedString("menu.edit.redo", comment: "Edit menu: Redo"),
            action: nil, keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(
            withTitle: NSLocalizedString("menu.edit.cut", comment: "Edit menu: Cut"),
            action: nil, keyEquivalent: "x")
        editMenu.addItem(
            withTitle: NSLocalizedString("menu.edit.copy", comment: "Edit menu: Copy"),
            action: nil, keyEquivalent: "c")
        editMenu.addItem(
            withTitle: NSLocalizedString("menu.edit.paste", comment: "Edit menu: Paste"),
            action: nil, keyEquivalent: "v")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(
            withTitle: NSLocalizedString(
                "menu.edit.clear",
                comment: "Edit menu: Clear item (clears the loaded SVG)"),
            action: #selector(AppDelegate.clearSVG),
            keyEquivalent: "")
        editMenuItem.submenu = editMenu

        // ── Window menu ───────────────────────────────────────────────────
        let windowMenuItem = mainMenu.addItem(
            withTitle: NSLocalizedString("menu.window", comment: "Window menu title"),
            action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(
            title: NSLocalizedString("menu.window", comment: "Window menu title"))
        windowMenu.addItem(
            withTitle: NSLocalizedString(
                "menu.window.minimize",
                comment: "Window menu: Minimize item"),
            action: #selector(NSWindow.miniaturize(_:)),
            keyEquivalent: "m")
        windowMenu.addItem(
            withTitle: NSLocalizedString(
                "menu.window.zoom",
                comment: "Window menu: Zoom item"),
            action: #selector(NSWindow.zoom(_:)),
            keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(
            withTitle: NSLocalizedString(
                "menu.window.bring_all_to_front",
                comment: "Window menu: Bring All to Front item"),
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        NSApplication.shared.windowsMenu = windowMenu

        // ── Help menu ─────────────────────────────────────────────────────
        let helpMenuItem = mainMenu.addItem(
            withTitle: NSLocalizedString("menu.help", comment: "Help menu title"),
            action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: NSLocalizedString("menu.help", comment: "Help menu title"))
        helpMenu.addItem(
            withTitle: NSLocalizedString(
                "menu.help.keyjig_help",
                comment: "Help menu: KeyJig Help item"),
            action: #selector(AppDelegate.showHelp),
            keyEquivalent: "?")
        helpMenu.addItem(.separator())
        helpMenu.addItem(
            withTitle: NSLocalizedString(
                "menu.help.keyjig_website",
                comment: "Help menu: KeyJig Website item"),
            action: #selector(AppDelegate.openKeyJigWebsite),
            keyEquivalent: "")
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
        return String(Int(dims.width.rounded()))
    }

    /// Returns the height of the SVG in the frontmost window as text.
    @objc dynamic var scriptingSVGHeight: String {
        guard let svg = frontWindowState?.svgString, !svg.isEmpty else { return "" }
        guard let dims = extractSVGDimensions(svgString: svg) else { return "" }
        return String(Int(dims.height.rounded()))
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
            button.setAccessibilityLabel(
                NSLocalizedString(
                    "accessibility.status_bar",
                    comment: "VoiceOver label for the menu bar icon"))
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

    /// Loads a vector file (SVG, PDF, or AI) into the given AppState.
    /// SVG is read synchronously; PDF/AI are converted via Inkscape on a background queue.
    private func loadFile(at url: URL, into state: AppState) {
        switch url.pathExtension.lowercased() {
        case "svg":
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                state.svgURL = url.path
                state.svgString = content
            } catch {
                log.error("error reading SVG: \(error.localizedDescription, privacy: .public)")
            }
        case "pdf", "ai":
            state.conversionStatus = .converting
            DispatchQueue.global(qos: .userInitiated).async {
                let svg = convertToSVGWithInkscape(inputURL: url)
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
        default:
            log.error("unsupported file type: \(url.pathExtension, privacy: .public)")
        }
    }

    /// Opens a vector file into whichever window is currently key.
    /// Falls back to the primary window if no key window can be found.
    /// Accepts SVG directly; converts PDF and AI via Inkscape when available.
    @objc func openSVGFile() {
        let dialog = NSOpenPanel()
        dialog.title = NSLocalizedString(
            "file_dialog.title",
            comment: "Title of the file open panel")
        dialog.showsHiddenFiles = false
        dialog.canChooseDirectories = false
        dialog.allowsMultipleSelection = false
        var types: [UTType] = [.svg]
        if inkscapeURL() != nil {
            types.append(.pdf)
            if let aiType = UTType(filenameExtension: "ai") {
                types.append(aiType)
            }
        }
        dialog.allowedContentTypes = types
        guard dialog.runModal() == .OK, let url = dialog.url else { return }
        guard let state = frontWindowState else { return }
        loadFile(at: url, into: state)
    }

    /// Clears the content of whichever window is currently key.
    @objc func clearSVG() {
        frontWindowState?.svgString = ""
        frontWindowState?.svgURL = ""
    }

    @objc func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "dialog.about.title",
            comment: "About dialog message text (app name)")
        alert.informativeText = String(
            format: NSLocalizedString(
                "dialog.about.info",
                comment: "About dialog informative text; %@ is replaced with the version number"),
            version)
        alert.alertStyle = .informational
        alert.addButton(
            withTitle: NSLocalizedString(
                "dialog.about.button",
                comment: "About dialog dismiss button"))
        alert.addButton(
            withTitle: NSLocalizedString(
                "dialog.about.website",
                comment: "About dialog button that opens the project website"))
        if alert.runModal() == .alertSecondButtonReturn {
            openKeyJigWebsite()
        }
    }

    @objc func showHelp() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "dialog.help.title",
            comment: "Help dialog title")
        alert.informativeText = NSLocalizedString(
            "dialog.help.info",
            comment: "Help dialog body text explaining the app workflow")
        alert.alertStyle = .informational
        alert.addButton(
            withTitle: NSLocalizedString(
                "dialog.help.button",
                comment: "Help dialog dismiss button"))
        alert.runModal()
    }

    @objc func openKeyJigWebsite() {
        NSWorkspace.shared.open(URL(string: "https://github.com/Cyzor/KeyJig")!)
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

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        let ext = url.pathExtension.lowercased()
        // Reject PDF/AI silently if Inkscape is absent — returning false lets the
        // system surface its own "can't open" feedback to the user.
        guard ext == "svg" || ((ext == "pdf" || ext == "ai") && inkscapeURL() != nil) else {
            return false
        }
        showMainWindow()
        guard let state = frontWindowState else { return false }
        loadFile(at: url, into: state)
        return true
    }

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
            withTitle: NSLocalizedString(
                "dock.show_window",
                comment: "Dock context menu: Show Window item"),
            action: #selector(showMainWindow),
            keyEquivalent: "")
        menu.addItem(
            withTitle: NSLocalizedString(
                "dock.new_viewer",
                comment: "Dock context menu: New Viewer item"),
            action: #selector(newFloatingWindow),
            keyEquivalent: "")
        return menu
    }

}
