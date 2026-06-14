import Cocoa
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import os

private let log = Logger(subsystem: "com.cyzor.KeyJig", category: "AppDelegate")

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

    /// About window controller (created lazily on first open).
    var aboutWindowController: AboutWindowController?

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

    /// Returns the POSIX path of the most recently produced output file.
    /// Prefers the Keynote-pulled PDF; falls back to the staged SVG bridge file.
    @objc dynamic var scriptingResultFilePath: String {
        guard let state = frontWindowState else { return "" }
        if let pdfURL = state.previewPDFURL { return pdfURL.path }
        if let svgURL = state.bridgeFileURL { return svgURL.path }
        return ""
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
            rootView: ContentView(appState: popoverAppState, isPopoverContext: true, isPopoverSurface: true))
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
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel(
                NSLocalizedString(
                    "accessibility.status_bar",
                    comment: "VoiceOver label for the menu bar icon"))

            // Transparent drag-destination overlay. hitTest returns nil so
            // regular clicks fall through to the button unimpeded; drag events
            // are routed directly by the drag manager and bypass hitTest.
            let proxy = StatusBarDragProxy(frame: button.bounds)
            proxy.autoresizingMask = [.width, .height]
            proxy.appDelegate = self
            button.addSubview(proxy)
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
            // Clipboard content has no source file — clear any stale origin
            // so the proxy icon and derived temp names don't show the
            // previous file's name.
            state.svgURL = ""
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
                state.svgURL = ""
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
    fileprivate var frontWindowState: AppState? {
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

    /// Toggles the menubar popover open or closed.
    /// Right-click shows a compact context menu instead.
    @objc func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusBarContextMenu()
            return
        }
        guard let popover = self.popover else { return }
        if popover.isShown { closePopover() } else { showPopover() }
    }

    private func showStatusBarContextMenu() {
        closePopover()

        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: NSLocalizedString("settings.window.title", comment: ""),
            action: #selector(openPreferences),
            keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let showItem = NSMenuItem(
            title: NSLocalizedString("menu.file.show_window", comment: ""),
            action: #selector(showMainWindow),
            keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: NSLocalizedString("menu.app.quit", comment: ""),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "")
        menu.addItem(quitItem)

        if let button = statusBarItem?.button {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.maxY),
                       in: button)
        }
    }

    /// Opens the menubar popover, mirroring the frontmost document window when
    /// one exists. No-op when the popover is already shown.
    ///
    /// Mirror target priority: most recently active document window
    /// (NSApp.mainWindow persists across app switches) → primary window →
    /// independent popoverAppState. The chosen AppState is locked in for the
    /// lifetime of this open; it does not change if the user switches windows
    /// while the popover is visible.
    private func showPopover() {
        guard let popover = self.popover, !popover.isShown,
              let button = statusBarItem?.button
        else { return }

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
                rootView: ContentView(appState: target, isPopoverContext: isIndependent, isPopoverSurface: true))
            activePopoverState = target
        }

        checkAndLoadClipboardSVG(into: target)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installPopoverDismissMonitor()
    }

    /// Called by StatusBarDragProxy when valid vector content enters the icon area.
    /// Opens the popover so the user can complete the drop inside the preview well.
    func openPopoverForDrag() {
        showPopover()
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
            // windowWillClose removed the controller from floatingWindows;
            // re-register it (at index 0 — session save expects the primary
            // first) so key-window resolution and session persistence see it.
            if !floatingWindows.contains(where: { $0 === existing }) {
                floatingWindows.insert(existing, at: 0)
            }
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

    /// Opens a new floating viewer window preloaded with an SVG string.
    /// Called when a multi-file drop produces more results than the target
    /// window can absorb (extras) or when the popover receives any drop (all).
    /// `sourceURL` is the dropped file's origin, when known — it feeds the
    /// proxy icon and content-derived temp names.
    func openNewFloatingWindow(withSVG svg: String, sourceURL: URL? = nil) {
        let wc = MainWindowController(isPrimary: false)
        if let last = floatingWindows.last?.window?.frame {
            wc.window?.setFrameOrigin(
                CGPoint(x: last.origin.x + 20, y: last.origin.y - 20))
        }
        wc.appState.svgURL = sourceURL?.path ?? ""
        wc.appState.svgString = svg
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
                switch checkedIngestSVG(content) {
                case .success(let safe):
                    state.svgURL = url.path
                    state.svgString = safe
                    state.statusMessage = ""
                    state.pendingOversizedSVG = nil
                case .failure(let err):
                    log.error("rejected SVG: \(url.lastPathComponent, privacy: .public)")
                    state.conversionStatus = .idle
                    if case .tooLarge(let bytes) = err {
                        state.statusMessage = ""
                        state.pendingOversizedSVG = (string: content, url: url.path, bytes: bytes)
                    } else {
                        state.statusMessage = err.userMessage
                        state.pendingOversizedSVG = nil
                    }
                }
            } catch {
                log.error("error reading SVG: \(error.localizedDescription, privacy: .public)")
                state.conversionStatus = .idle
                state.statusMessage = SVGIngestError.notSVG.userMessage
            }
        case "pdf", "ai":
            if ext == "ai", sniffVectorFileType(at: url) != "pdf" {
                state.conversionStatus = .idle
                state.statusMessage = NSLocalizedString("error.ai.no_pdf_layer", comment: "")
                return
            }
            state.statusMessage = ""
            state.pendingOversizedSVG = nil
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
            state.conversionStatus = .idle
            state.statusMessage = SVGIngestError.notSVG.userMessage
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

    /// Clears the content of whichever window is currently key, registering
    /// undo with that window so ⌘Z reverses it.
    @objc func clearSVG() {
        guard let state = frontWindowState else { return }
        state.clearContent(registeringWith: undoManager(for: state))
    }

    /// Resolves the undo manager that owns deletions for the given state:
    /// the document window holding it, or the popover's window when the
    /// state is shown there. NSWindow creates its undo manager lazily.
    func undoManager(for state: AppState) -> UndoManager? {
        if let wc = floatingWindows.first(where: { $0.appState === state }) {
            return wc.window?.undoManager
        }
        return popover?.contentViewController?.view.window?.undoManager
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
        guard let state = frontWindowState, !state.svgString.isEmpty else { return }
        _ = svgToClipboard(svgData: state.svgString, appState: state)
        state.statusMessage = NSLocalizedString(
            "status.copied",
            comment: "Confirmation shown after copying to clipboard")
    }

    @objc func menuPlaceInKeynote(_ sender: Any?) {
        guard let state = frontWindowState, !state.svgString.isEmpty else { return }
        state.keynoteSendStatus = .sending
        state.statusMessage = NSLocalizedString(
            "status.keynote.sending",
            comment: "Status: SVG is being placed into Keynote")
        sendSVGToKeynote(svgData: state.svgString, originPath: state.svgURL) { error in
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

    /// Edit ▸ Undo / Redo. These use the standard selectors with a nil
    /// target, so a focused text field handles its own undo first; when
    /// nothing earlier in the responder chain claims the action, it lands
    /// here and drives the window's undo manager — reversing destructive
    /// actions (canvas clears). ⌘[ / ⌘] history navigation is separate.
    @objc func undo(_ sender: Any?) {
        frontWindowState.flatMap(undoManager(for:))?.undo()
    }

    @objc func redo(_ sender: Any?) {
        frontWindowState.flatMap(undoManager(for:))?.redo()
    }

    /// Edit ▸ Back / Forward (⌘[ / ⌘]) — per-window content history.
    @objc func historyBack(_ sender: Any?) {
        frontWindowState?.goBack()
    }

    @objc func historyForward(_ sender: Any?) {
        frontWindowState?.goForward()
    }

    /// validateMenuItem disables menu items that mirror button disabled states.
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            return frontWindowState.flatMap(undoManager(for:))?.canUndo ?? false
        case #selector(redo(_:)):
            return frontWindowState.flatMap(undoManager(for:))?.canRedo ?? false
        case #selector(historyBack(_:)):
            return frontWindowState?.canGoBack ?? false
        case #selector(historyForward(_:)):
            return frontWindowState?.canGoForward ?? false
        case #selector(menuConvertKeynoteSlide):
            return frontWindowState?.keynoteRunning == true
                && frontWindowState?.keynoteAutomationGranted != false
        case #selector(menuConvertKeynoteClipboard):
            return frontWindowState?.keynoteRunning == true
                && frontWindowState?.keynoteClipboardReady == true
                && frontWindowState?.keynoteAutomationGranted != false
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
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController()
        }
        aboutWindowController?.showWindow()
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

// MARK: - StatusBarDragProxy

/// Transparent overlay placed on the status bar button to accept inbound vector drags.
///
/// When recognized content enters the icon area the popover opens immediately,
/// revealing the preview well as the drop target. The user can then move the drag
/// into the popover and release there — SVGInteractionView handles the drop exactly
/// as it does for any other inbound drag.
///
/// If the user releases directly on the icon (without moving into the popover),
/// performDragOperation loads the content into the frontmost window as a fallback.
///
/// hitTest always returns nil so regular mouse clicks fall through to the underlying
/// NSStatusBarButton unimpeded. Drag events bypass hitTest and are delivered by the
/// drag manager directly to registered destination views.
private final class StatusBarDragProxy: NSView {

    weak var appDelegate: AppDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(SVGInteractionView.acceptedTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(SVGInteractionView.acceptedTypes)
    }

    // Let all regular mouse events fall through to the button below.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard SVGInteractionView.canHandleDropData(sender.draggingPasteboard) else { return [] }
        appDelegate?.openPopoverForDrag()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        SVGInteractionView.canHandleDropData(sender.draggingPasteboard) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        SVGInteractionView.canHandleDropData(sender.draggingPasteboard)
    }

    /// Handles the rare case where the user releases on the icon itself rather
    /// than moving into the opened popover. For multi-file drops all results go
    /// to floating windows; for single files the front window receives the content.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let fileURLs = SVGInteractionView.validFileURLs(from: pb)
        if fileURLs.count > 1 {
            let state = appDelegate?.frontWindowState
            state?.conversionStatus = .converting
            SVGInteractionView.processFilesSerially(fileURLs) { [weak self] items, rejections in
                state?.conversionStatus = .idle
                if items.isEmpty {
                    state?.statusMessage = rejections.first ?? SVGIngestError.notSVG.userMessage
                    return
                }
                for item in items {
                    self?.appDelegate?.openNewFloatingWindow(
                        withSVG: item.svg, sourceURL: item.sourceURL)
                }
            }
            return true
        }
        guard let state = appDelegate?.frontWindowState else { return false }
        switch SVGInteractionView.dropOutcome(from: pb) {
        case .loaded(let dropped):
            state.svgURL = dropped.sourceURL?.path ?? ""
            state.svgString = dropped.svg
            state.statusMessage = ""
            state.pendingOversizedSVG = nil
            return true
        case .rejected(let reason, let oversized):
            state.conversionStatus = .idle
            if let (string, url, bytes) = oversized {
                state.statusMessage = ""
                state.pendingOversizedSVG = (string: string, url: url, bytes: bytes)
            } else {
                state.statusMessage = reason
                state.pendingOversizedSVG = nil
            }
            return true
        case .notHandled:
            return false
        }
    }
}
