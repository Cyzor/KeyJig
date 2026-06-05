import Cocoa
import Combine
import SwiftUI
import os

private let log = Logger(subsystem: "com.cyzor.KeyJig", category: "MainWindow")

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

    private var untitledTitle: String { Self.untitledTitle(for: windowNumber) }

    private var representedURLCancellable: AnyCancellable?
    private var minWidthCancellable: AnyCancellable?
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

        window.isExcludedFromWindowsMenu = false

        if isPrimary {
            // Setting the autosave name AFTER super.init means AppKit can
            // actually find and restore the previously saved frame.
            // If no saved frame exists yet, centre the window.
            let didRestore = window.setFrameUsingName("KeyJigMainWindow")
            if !didRestore { window.center() }
            window.setFrameAutosaveName("KeyJigMainWindow")
        } else {
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
                DispatchQueue.main.async { self?.updateRepresentedURL() }
            }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: Proxy icon

    func updateRepresentedURL() {
        guard !appState.svgString.isEmpty else {
            window?.representedURL = nil
            window?.title = untitledTitle
            return
        }

        if let bridgeURL = appState.bridgeFileURL,
            FileManager.default.fileExists(atPath: bridgeURL.path)
        {
            window?.representedURL = bridgeURL
            window?.title = bridgeURL.deletingPathExtension().lastPathComponent
            return
        }

        if !appState.svgURL.isEmpty {
            let sourceURL = URL(fileURLWithPath: appState.svgURL)
            window?.representedURL = sourceURL
            window?.title = sourceURL.deletingPathExtension().lastPathComponent
            return
        }

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
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let outerPadding: CGFloat = 16 * 2
        let minW = appState.minimumButtonAreaWidth > 0
            ? (appState.minimumButtonAreaWidth + outerPadding).rounded(.up)
            : 320
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
