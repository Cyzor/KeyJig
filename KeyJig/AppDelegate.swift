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

    /// Monotonic source of per-window numbers. Never reused, so two open windows
    /// always carry distinct numbers even after others have closed.
    private static var nextWindowNumber = 1

    /// Stable ordinal used to distinguish otherwise-identical "KeyJig" windows.
    let windowNumber: Int

    /// Title shown when the window holds no named file. The first window is the
    /// bare app name; later windows carry their number (mirrors TextEdit's
    /// "Untitled", "Untitled 2", …). Static so it can be used before super.init.
    private static func untitledTitle(for number: Int) -> String {
        guard number > 1 else {
            return NSLocalizedString(
                "window.title.base",
                comment: "Window title for the first/only unnamed window")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString(
                "window.title.numbered",
                comment: "Window title for an unnamed window, with its number, e.g. 'KeyJig 2'"),
            number)
    }

    /// Title shown when the window holds no named file.
    private var untitledTitle: String { Self.untitledTitle(for: windowNumber) }

    /// Retains the Combine subscription that keeps the proxy icon current.
    private var representedURLCancellable: AnyCancellable?
    /// Retains the subscription that applies the measured minimum content width.
    private var minWidthCancellable: AnyCancellable?
    /// Retains the subscription that grows the window when the accessibility notice appears.
    private var noticeHeightCancellable: AnyCancellable?

    init(appState: AppState = AppState(), isPrimary: Bool = false) {
        self.appState = appState
        self.windowNumber = MainWindowController.nextWindowNumber
        MainWindowController.nextWindowNumber += 1

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.title = Self.untitledTitle(for: windowNumber)
        window.minSize = NSSize(width: 0, height: 520)
        window.maxSize = NSSize(width: 900, height: 1200)

        super.init(window: window)

        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: ContentView(appState: appState))

        // After ContentView's first layout pass its invisible button probe fires
        // ButtonAreaMinWidthKey, which ContentView writes to appState.minimumButtonAreaWidth.
        // Apply it here as the window's content minimum width (adding the outer
        // padding that the probe sits inside of). Using .first() so we only set
        // it once — button labels don't change at runtime.
        minWidthCancellable = appState.$minimumButtonAreaWidth
            .filter { $0 > 0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] buttonAreaWidth in
                guard let win = self?.window else { return }
                let outerPadding: CGFloat = 16 * 2  // VStack .padding(.horizontal, 16)
                let minW = (buttonAreaWidth + outerPadding).rounded(.up)
                win.contentMinSize = NSSize(width: minW, height: 0)
                if win.frame.width < minW {
                    var f = win.frame; f.size.width = minW
                    win.setFrame(f, display: true, animate: false)
                }
            }

        // Track the measured height of below-preview content and use it to set a
        // correct minimum window height. The GeometryReader in ContentView reports
        // the actual rendered height (including any accessibility notice text-wrap),
        // so the window never clips at any width or locale.
        noticeHeightCancellable = appState.$minimumBelowPreviewHeight
            .filter { $0 > 0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] belowH in
                guard let self = self, let win = self.window else { return }
                let titleH = win.frame.height - win.contentLayoutRect.height
                let previewMinH: CGFloat = 200  // .frame(minHeight:) in ContentView
                let previewTopPad: CGFloat = 16 // .padding([.horizontal, .top])
                let outerSpacing: CGFloat = 4   // VStack(spacing: 4) gap
                let contentMinH = previewTopPad + previewMinH + outerSpacing + belowH
                let newMinH = max(520, (titleH + contentMinH).rounded(.up))
                win.minSize.height = newMinH
                guard win.frame.height < newMinH else { return }
                var f = win.frame
                f.origin.y -= (newMinH - f.size.height)  // keep top edge stable
                f.size.height = newMinH
                if let screen = win.screen {
                    f.origin.y = max(f.origin.y, screen.visibleFrame.minY)
                }
                win.setFrame(f, display: true, animate: true)
            }

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
            window?.title = untitledTitle
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
        window?.title = untitledTitle
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        AppDelegate.shared?.floatingWindows.removeAll { $0 === self }
    }

    /// Enforces the minimum width during user drag-resize.
    /// NSHostingController can override contentMinSize by propagating the
    /// SwiftUI content's own compressed size, but it cannot override a value
    /// returned from this delegate method.
    /// appState.minimumButtonAreaWidth is set by ContentView's invisible probe
    /// during layout; outerPadding matches VStack .padding(.horizontal, 16).
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let outerPadding: CGFloat = 16 * 2
        let minW = appState.minimumButtonAreaWidth > 0
            ? (appState.minimumButtonAreaWidth + outerPadding).rounded(.up)
            : 320  // safe fallback until the first layout fires
        return NSSize(width: max(frameSize.width, minW), height: frameSize.height)
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
        let hideOthers = appMenu.addItem(
            withTitle: NSLocalizedString(
                "menu.app.hide_others",
                comment: "App menu: Hide Others item"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
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
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(
            withTitle: NSLocalizedString(
                "menu.file.convert_keynote_slide",
                comment: "File menu: Convert Keynote Slide to PDF"),
            action: #selector(AppDelegate.menuConvertKeynoteSlide),
            keyEquivalent: "r")
        fileMenu.addItem(
            withTitle: NSLocalizedString(
                "menu.file.convert_keynote_clipboard",
                comment: "File menu: Convert Keynote Clipboard to PDF"),
            action: #selector(AppDelegate.menuConvertKeynoteClipboard),
            keyEquivalent: "e")
        fileMenu.addItem(
            withTitle: NSLocalizedString(
                "menu.file.place_in_keynote",
                comment: "File menu: Place SVG in Keynote"),
            action: #selector(AppDelegate.menuPlaceInKeynote),
            keyEquivalent: "d")
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
                "menu.edit.copy_for_keynote",
                comment: "Edit menu: Copy for Keynote"),
            action: #selector(AppDelegate.menuCopyForKeynote),
            keyEquivalent: "k")
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
        helpMenu.addItem(.separator())
        helpMenu.addItem(
            withTitle: NSLocalizedString(
                "menu.help.reveal_preferences",
                comment: "Help menu: reveal the app preferences plist in Finder"),
            action: #selector(AppDelegate.revealPreferencesPlist),
            keyEquivalent: "")
        helpMenuItem.submenu = helpMenu

        NSApplication.shared.mainMenu = mainMenu
    }
}

// MARK: - Session State

/// Writes and reads per-session SVG snapshots for windows whose content
/// came from the clipboard (no on-disk file URL of the user's own).
private enum SessionFiles {
    static var directory: URL {
        let id = Bundle.main.bundleIdentifier ?? "com.cyzor.KeyJig"
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(id + "/session")
    }

    /// Writes `svg` to a stable named slot under the session directory.
    /// Returns the file URL on success, nil on write failure.
    static func write(_ svg: String, slot name: String) -> URL? {
        let dir = directory
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name + ".svg")
        return (try? svg.write(to: url, atomically: true, encoding: .utf8)) == nil
            ? nil : url
    }

    static func isSessionFile(_ url: URL) -> Bool {
        url.path.hasPrefix(directory.path)
    }
}

/// Codable wrapper around NSRect.
private struct CodableRect: Codable {
    var x, y, w, h: Double
    init(_ r: NSRect) {
        x = Double(r.origin.x); y = Double(r.origin.y)
        w = Double(r.size.width); h = Double(r.size.height)
    }
    var nsRect: NSRect { NSRect(x: x, y: y, width: w, height: h) }
}

/// State for one document window.
private struct WindowEntry: Codable {
    /// User's original file path, or a SessionFiles snapshot path.  nil = empty window.
    var contentURL: String?
    /// Frame of the window at quit time.
    var frame: CodableRect
    /// Windows sharing the same non-nil tabGroupID are part of one tab bar.
    var tabGroupID: Int?
    /// True when this window was the selected (frontmost) tab in its group at quit time.
    var isSelectedTab: Bool

    init(contentURL: String?, frame: CodableRect, tabGroupID: Int?, isSelectedTab: Bool = false) {
        self.contentURL = contentURL
        self.frame = frame
        self.tabGroupID = tabGroupID
        self.isSelectedTab = isSelectedTab
    }

    // Custom decoder so old session records missing `isSelectedTab` still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contentURL   = try c.decodeIfPresent(String.self,      forKey: .contentURL)
        frame        = try c.decode(CodableRect.self,           forKey: .frame)
        tabGroupID   = try c.decodeIfPresent(Int.self,          forKey: .tabGroupID)
        isSelectedTab = (try? c.decode(Bool.self, forKey: .isSelectedTab)) ?? false
    }
}

/// Persists the complete window arrangement at last quit. Stored as JSON in UserDefaults.
private struct SessionState: Codable {
    /// All document windows in creation order; index 0 is always the primary window.
    var windows: [WindowEntry]

    static let defaultsKey = "SessionState"

    static func load() -> SessionState? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: SessionState.defaultsKey)
        }
    }
}

// MARK: - AppDelegate

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

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

    /// Global event monitor that closes the popover on mouseUp outside its frame.
    /// Registered when the popover opens; torn down when it closes or the monitor
    /// fires. Using mouseUp (not mouseDown) so a drag from outside can still land
    /// inside the popover — the window stays visible during the drag gesture.
    private var popoverDismissMonitor: Any?

    /// Settings window controller (created lazily when user opens preferences).
    var settingsWindowController: SettingsWindowController?

    /// Help window controller (created lazily on first open).
    var helpWindowController: HelpWindowController?

    /// The AppState currently displayed in the popover.
    /// When a document window was frontmost at open time this is a reference to
    /// that window's AppState — the popover mirrors it.
    /// Falls back to the independent popoverAppState when no doc window exists.
    /// Cleared in popoverDidClose. Strong because NSHostingController already
    /// retains AppState independently; weak would mislead without saving memory.
    private var activePopoverState: AppState?

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
            rootView: ContentView(appState: popoverAppState, isPopoverContext: true))
        // .applicationDefined suppresses AppKit's built-in click-outside-to-close
        // logic. We install our own global mouseUp monitor instead so a drag from
        // outside can enter the popover before the release dismisses it.
        popover.behavior = .applicationDefined
        popover.delegate = self
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

        // Restore last session. Only fall through to clipboard seeding when
        // restore left the primary window empty — a restored SVG must not be
        // silently overwritten by whatever happens to be on the clipboard.
        let restored = restoreSession(into: wc)
        if !restored {
            checkAndLoadClipboardSVG(into: wc.appState)
        }

        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Recreates the window arrangement and document state saved at last quit.
    /// Returns true if content was restored into the primary window.
    @discardableResult
    private func restoreSession(into primary: MainWindowController) -> Bool {
        guard let state = SessionState.load(), !state.windows.isEmpty else { return false }

        // ── 1. Create controllers and restore frames/content ────────────────
        var controllers: [MainWindowController] = []
        var primaryRestored = false

        for (i, entry) in state.windows.enumerated() {
            let wc: MainWindowController
            if i == 0 {
                wc = primary
            } else {
                wc = MainWindowController(isPrimary: false)
                floatingWindows.append(wc)
            }
            // Apply the saved frame before the window is shown.
            wc.window?.setFrame(entry.frame.nsRect, display: false)

            if let urlString = entry.contentURL {
                let loaded = loadSessionContent(
                    from: URL(fileURLWithPath: urlString), into: wc.appState)
                if i == 0 && loaded { primaryRestored = true }
            }
            controllers.append(wc)
        }

        // ── 2. Restore tab groups ────────────────────────────────────────────
        // Collect windows by their saved tab-group ID, then merge them with
        // addTabbedWindow(_:ordered:). Windows are shown before merging so
        // AppKit has valid on-screen targets to group.
        var tabGroups: [Int: [NSWindow]] = [:]
        for (i, entry) in state.windows.enumerated() {
            if let gid = entry.tabGroupID, let win = controllers[i].window {
                tabGroups[gid, default: []].append(win)
            }
        }

        // ── 3. Show windows back-to-front so the first entry ends up on top ─
        // Secondary windows are shown here; the primary is shown again (harmlessly)
        // by applicationDidFinishLaunching after we return.
        for wc in controllers.reversed() {
            wc.window?.makeKeyAndOrderFront(nil)
        }

        // Merge tab groups after all windows are on screen.
        for (_, group) in tabGroups.sorted(by: { $0.key < $1.key }) {
            guard group.count > 1 else { continue }
            let anchor = group[0]
            for other in group.dropFirst() {
                anchor.addTabbedWindow(other, ordered: .above)
            }
        }

        // Select the tab that was active at quit time.
        for (i, entry) in state.windows.enumerated() {
            guard entry.isSelectedTab, let win = controllers[i].window else { continue }
            win.tabGroup?.selectedWindow = win
        }

        // Help and Settings are not restored on relaunch — they open on demand
        // and remember their position via setFrameAutosaveName.

        return primaryRestored
    }

    /// Loads SVG content from a URL into an AppState.
    /// Session files are read directly into svgString without setting svgURL
    /// (they're treated as clipboard-equivalent; no proxy icon).
    /// User files go through loadFile(), which sets svgURL for the proxy icon.
    @discardableResult
    private func loadSessionContent(from url: URL, into appState: AppState) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if SessionFiles.isSessionFile(url) {
            guard let svg = try? String(contentsOf: url, encoding: .utf8),
                  !svg.isEmpty else { return false }
            appState.svgString = svg
            return true
        }
        loadFile(at: url, into: appState)
        return true
    }

    // MARK: Clipboard helper

    /// Pushes clipboard content into `state` when the clipboard has changed.
    ///
    /// Priority order:
    ///   1. Keynote slide — `com.apple.iWork.TSPNativeData` co-present with
    ///      `com.adobe.pdf` is an unambiguous Keynote fingerprint. The PDF is
    ///      used directly in PDF-preview mode; Inkscape is not involved, which
    ///      avoids the color-fidelity issues its SVG output causes in InDesign.
    ///      This path fires regardless of current well state.
    ///   2. Native SVG — fast, synchronous.
    ///   3. PDF/AI via Inkscape — slow, async; only when well is empty.
    private func checkAndLoadClipboardSVG(into state: AppState) {
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != state.lastLoadedClipboardChangeCount else { return }

        let pasteboardTypes = Set(pasteboard.types ?? [])
        let iWorkType = NSPasteboard.PasteboardType("com.apple.iWork.TSPNativeData")

        if pasteboardTypes.contains(iWorkType) {
            let pdfData = pasteboard.data(
                forType: NSPasteboard.PasteboardType("com.adobe.pdf"))
                ?? pasteboard.data(
                    forType: NSPasteboard.PasteboardType("Apple PDF pasteboard type"))
            if let data = pdfData, !data.isEmpty {
                let outURL = makeTempKeynotePDFURL()
                do {
                    try data.write(to: outURL)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o600], ofItemAtPath: outURL.path)
                    state.previewPDFURL = outURL
                    state.lastLoadedClipboardChangeCount = currentChangeCount
                } catch {
                    log.error("Keynote clipboard PDF write failed: \(error.localizedDescription, privacy: .public)")
                }
                return
            }
        }

        // Fast path — native SVG, completes instantly.
        let svg = convertClipboardToSVG()
        if !svg.isEmpty, svg != state.svgString {
            state.svgString = svg
            state.lastLoadedClipboardChangeCount = currentChangeCount
            return
        }

        // Slow path — only attempt if the window is empty, there is convertible
        // data on the clipboard, and Inkscape is actually installed.
        guard state.svgString.isEmpty,
            clipboardHasConvertibleVectorData(),
            inkscapeURL() != nil
        else { return }

        state.conversionStatus = .converting
        state.lastLoadedClipboardChangeCount = currentChangeCount
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
    ///   1. The pinned menu-bar popover, whenever it is visible — it floats
    ///      above every window and is the user's active surface while open.
    ///   2. A window in our floatingWindows list that is currently key.
    ///   3. NSApp.keyWindow if it belongs to one of our controllers (covers
    ///      the brief window between activation and key-window assignment).
    ///   4. The primary window as the final fallback.
    private var frontWindowState: AppState? {
        if popover?.isShown == true {
            return activePopoverState ?? popoverAppState
        }
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

    /// Toggles the menubar popover.
    ///
    /// When a document window was most recently active, the popover mirrors it —
    /// the same AppState object is shared, so content and actions are identical.
    /// When no document window exists the popover is fully independent.
    /// The chosen AppState is locked in for the lifetime of this open; it does
    /// not change if the user switches windows while the popover is visible.
    @objc func togglePopover() {
        guard let popover = self.popover,
            let button = statusBarItem?.button
        else { return }
        if popover.isShown {
            closePopover()
            return
        }

        // Resolve the mirror target: prefer the most recently active document
        // window (NSApp.mainWindow persists across app switches), then the
        // primary window, then fall back to the independent popoverAppState.
        let target: AppState
        let mirrorWindow = NSApp.mainWindow ?? NSApp.keyWindow
        if let win = mirrorWindow,
           let wc = floatingWindows.first(where: { $0.window === win }) {
            target = wc.appState
        } else if let primary = primaryWindowController {
            target = primary.appState
        } else {
            target = popoverAppState
        }

        // Recreate the hosting controller only when the target changes.
        // Because this happens before show(), there is no visible flash.
        if activePopoverState !== target {
            let isIndependent = target === popoverAppState
            popover.contentViewController = NSHostingController(
                rootView: ContentView(appState: target, isPopoverContext: isIndependent))
            activePopoverState = target
        }

        checkAndLoadClipboardSVG(into: target)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installPopoverDismissMonitor()
    }

    /// Closes the popover and tears down the dismiss event monitor.
    func closePopover() {
        popover?.performClose(nil)
        removePopoverDismissMonitor()
    }

    /// Installs a global mouseUp monitor that closes the popover when the
    /// release occurs outside the popover's window frame.
    private func installPopoverDismissMonitor() {
        guard popoverDismissMonitor == nil else { return }
        popoverDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { [weak self] event in
            guard let self,
                  let popover = self.popover,
                  popover.isShown,
                  let popoverWindow = popover.contentViewController?.view.window
            else { return }

            // Convert the cursor position to the popover window's coordinate space.
            let screenPoint = NSEvent.mouseLocation
            let windowFrame = popoverWindow.frame
            if !windowFrame.contains(screenPoint) {
                self.closePopover()
            }
        }
    }

    /// Removes the global mouseUp monitor if one is installed.
    private func removePopoverDismissMonitor() {
        if let monitor = popoverDismissMonitor {
            NSEvent.removeMonitor(monitor)
            popoverDismissMonitor = nil
        }
    }

    // MARK: NSPopoverDelegate

    /// Cleans up the dismiss monitor whenever the popover closes, regardless of
    /// how it was closed (toggle button, Escape, or our own mouseUp monitor).
    func popoverDidClose(_ notification: Notification) {
        removePopoverDismissMonitor()
        activePopoverState = nil
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
    /// Reads SVG synchronously; converts PDF/AI via Inkscape on a background queue.
    /// For files with unknown or missing extensions, sniffs the content to determine type.
    private func loadFile(at url: URL, into state: AppState) {
        let ext = url.pathExtension.lowercased()
        let type = ["svg", "pdf", "ai"].contains(ext) ? ext
            : (sniffVectorFileType(at: url) ?? ext)

        switch type {
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
            log.error("unsupported file type: \(url.lastPathComponent, privacy: .public)")
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

    // MARK: - Keynote action selectors (menu ↔ button parity)

    @objc func menuConvertKeynoteSlide(_ sender: Any?) {
        guard let state = frontWindowState else { return }
        triggerKeynoteSlide(appState: state) { state.statusMessage = $0 }
    }

    @objc func menuConvertKeynoteClipboard(_ sender: Any?) {
        guard let state = frontWindowState else { return }
        triggerKeynoteClipboard(appState: state) { state.statusMessage = $0 }
    }

    @objc func menuCopyForKeynote(_ sender: Any?) {
        guard let state = frontWindowState else { return }
        let svg = convertClipboardToSVG()
        if !svg.isEmpty {
            state.svgString = svg
            state.conversionStatus = .idle
            _ = svgToClipboard(svgData: svg, appState: state)
        } else {
            state.statusMessage = NSLocalizedString(
                "status.no_svg_on_clipboard",
                comment: "Error message when no SVG is found on the clipboard")
        }
    }

    @objc func menuPlaceInKeynote(_ sender: Any?) {
        guard let state = frontWindowState, !state.svgString.isEmpty else { return }
        state.keynoteSendStatus = .sending
        state.statusMessage = NSLocalizedString(
            "status.keynote.sending",
            comment: "Status: SVG is being placed into Keynote")
        sendSVGToKeynote(svgData: state.svgString) { error in
            if let error = error {
                state.keynoteSendStatus = .failed
                state.statusMessage = error.localizedDescription
            } else {
                state.keynoteSendStatus = .succeeded
                state.statusMessage = NSLocalizedString(
                    "status.keynote.success",
                    comment: "Status: SVG was placed in Keynote successfully")
            }
        }
    }

    /// validateMenuItem disables menu items that mirror button disabled states.
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(menuConvertKeynoteSlide):
            return frontWindowState?.keynoteRunning == true
        case #selector(menuConvertKeynoteClipboard):
            return frontWindowState?.keynoteClipboardReady == true
        case #selector(menuCopyForKeynote):
            return !(frontWindowState?.svgString.isEmpty ?? true)
        case #selector(menuPlaceInKeynote):
            return !(frontWindowState?.svgString.isEmpty ?? true)
                && (frontWindowState?.accessibilityGranted ?? false)
        default:
            return true
        }
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
        if helpWindowController == nil {
            helpWindowController = HelpWindowController()
        }
        helpWindowController?.showWindow()
    }

    @objc func openKeyJigWebsite() {
        NSWorkspace.shared.open(URL(string: "https://github.com/Cyzor/KeyJig")!)
    }

    /// Reveals the app's preferences plist in Finder. Useful for troubleshooting
    /// persisted state such as the autosaved window frames.
    @objc func revealPreferencesPlist() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let plistURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(bundleID).plist")

        if FileManager.default.fileExists(atPath: plistURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([plistURL])
        } else {
            // No plist yet — open the containing Preferences folder instead.
            NSWorkspace.shared.open(plistURL.deletingLastPathComponent())
        }
    }

    @objc func openPreferences() {
        if settingsWindowController == nil {
            let appState = primaryWindowController?.appState ?? AppState()
            settingsWindowController = SettingsWindowController(appState: appState)
        }
        settingsWindowController?.showWindow()
    }

    // MARK: NSApplicationDelegate

    func applicationWillTerminate(_ notification: Notification) {
        func persistURL(for appState: AppState, slot: String) -> String? {
            if !appState.svgURL.isEmpty { return appState.svgURL }
            if !appState.svgString.isEmpty {
                return SessionFiles.write(appState.svgString, slot: slot)?.path
            }
            return nil
        }

        // Assign a stable integer to each distinct NSWindowTabGroup.
        var tabGroupMap: [ObjectIdentifier: Int] = [:]
        var nextGroupID = 0
        for wc in floatingWindows {
            guard let window = wc.window,
                  let group = window.tabGroup,
                  group.windows.count > 1 else { continue }
            let key = ObjectIdentifier(group)
            if tabGroupMap[key] == nil {
                tabGroupMap[key] = nextGroupID
                nextGroupID += 1
            }
        }

        let entries = floatingWindows.enumerated().compactMap { i, wc -> WindowEntry? in
            guard let window = wc.window else { return nil }
            let slot = i == 0 ? "primary" : "secondary-\(i - 1)"
            let tabGroupID = window.tabGroup.flatMap { tabGroupMap[ObjectIdentifier($0)] }
            let isSelectedTab = window.tabGroup?.selectedWindow === window
            return WindowEntry(
                contentURL: persistURL(for: wc.appState, slot: slot),
                frame: CodableRect(window.frame),
                tabGroupID: tabGroupID,
                isSelectedTab: isSelectedTab)
        }

        SessionState(windows: entries).save()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        let ext = url.pathExtension.lowercased()
        // Resolve type from extension; fall back to content sniffing for unknown extensions.
        let type = ["svg", "pdf", "ai"].contains(ext) ? ext
            : (sniffVectorFileType(at: url) ?? ext)
        // Reject PDF/AI silently if Inkscape is absent — returning false lets the
        // system surface its own "can't open" feedback to the user.
        guard type == "svg" || ((type == "pdf" || type == "ai") && inkscapeURL() != nil) else {
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

    func applicationDidBecomeActive(_ notification: Notification) {
        // On reactivation (e.g. switching back from Illustrator), seed the
        // front window with whatever is now on the clipboard. Using Did (not
        // Will) so that the key window is fully assigned before frontWindowState
        // resolves it — Will fires before the key window transfers, causing
        // clipboard content to land in the primary window regardless of which
        // window the user was working in.
        // frontWindowState already accounts for the popover's active state,
        // so no separate popover seeding is needed here.
        if let state = frontWindowState {
            checkAndLoadClipboardSVG(into: state)
        }
    }

    // MARK: Dock menu

    @objc func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
//        menu.addItem(
//            withTitle: NSLocalizedString(
//                "dock.show_window",
//                comment: "Dock context menu: Show Window item"),
//            action: #selector(showMainWindow),
//            keyEquivalent: "")
        menu.addItem(
            withTitle: NSLocalizedString(
                "dock.new_viewer",
                comment: "Dock context menu: New Viewer item"),
            action: #selector(newFloatingWindow),
            keyEquivalent: "")

        menu.addItem(.separator())

        let placeItem = NSMenuItem(
            title: NSLocalizedString(
                "menu.file.place_in_keynote",
                comment: "File menu: Place SVG in Keynote"),
            action: #selector(menuPlaceInKeynote),
            keyEquivalent: "")
        placeItem.target = self
        let state = frontWindowState
        placeItem.isEnabled = !(state?.svgString.isEmpty ?? true)
            && (state?.accessibilityGranted ?? false)
        menu.addItem(placeItem)

        return menu
    }

}
