import Combine
import Foundation
import SwiftUI
import AppKit
import WebKit
import os

private let log = Logger(subsystem: "com.cyzor.KeyJig", category: "AppState")

// MARK: - Clipboard Watcher

/// Single app-wide pasteboard poller. Every AppState used to run its own
/// 0.5 s timer; with several windows plus the popover that multiplied the
/// polling for no benefit. One timer publishes the change count; each
/// AppState subscribes and re-evaluates its own derived state.
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()

    /// Current pasteboard change count. Seeds subscribers immediately and
    /// fires again whenever the count moves.
    let changeCount: CurrentValueSubject<Int, Never>

    private var timer: Timer?

    private init() {
        changeCount = CurrentValueSubject(NSPasteboard.general.changeCount)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let count = NSPasteboard.general.changeCount
            if count != self.changeCount.value {
                self.changeCount.send(count)
            }
        }
        timer.tolerance = 0.1
        // .common keeps the clipboard watch ticking during menu tracking and
        // modal panels (e.g. the open-file dialog), where the default mode pauses.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

// MARK: - App State

/// Tracks SVG content and conversion state for a single window or popover.
/// Each window owns its own AppState — changes in one window never affect another.
class AppState: ObservableObject {
    @Published var svgURL: String = ""
    @Published var svgString: String = "" {
        didSet {
            if !svgString.isEmpty && previewPDFURL != nil {
                previewPDFURL = nil
            }
            // Cache metadata so views never run regex in their body.
            if svgString.isEmpty {
                svgDimensions = nil
                svgFileSize = ""
                svgCreator = nil
                svgHasText = false
                renderedPDFData = nil
            } else {
                renderedPDFData = nil
                svgDimensions = extractSVGDimensions(svgString: svgString)
                svgFileSize = getFileSizeString(svgString: svgString)
                svgCreator = extractSVGCreator(svgString: svgString)
                svgHasText = svgString.range(of: "<text[\\s>]", options: .regularExpression) != nil
                scheduleHistoryCapture()
            }
        }
    }
    /// Cached result of extractSVGDimensions — updated whenever svgString changes.
    private(set) var svgDimensions: (width: Double, height: Double)? = nil
    /// Cached result of getFileSizeString — updated whenever svgString changes.
    private(set) var svgFileSize: String = ""
    /// Cached result of extractSVGCreator — updated whenever svgString changes.
    private(set) var svgCreator: String? = nil
    /// True when the SVG contains <text> elements (live text, not just outlined paths).
    private(set) var svgHasText: Bool = false

    /// Cached PDF page dimensions — updated whenever previewPDFURL changes.
    private(set) var pdfDimensions: (width: Double, height: Double)? = nil
    /// Cached PDF file size string — updated whenever previewPDFURL changes.
    private(set) var pdfFileSize: String = ""

    /// Human-readable label for the content format currently on the canvas.
    var contentFormatLabel: String? {
        if previewPDFURL != nil { return "PDF" }
        if !svgString.isEmpty { return svgHasText ? "SVG + Text" : "SVG" }
        return nil
    }
    /// The last temp file written by svgToClipboard() or an outbound drag.
    /// Stored here so the proxy icon can find it even though each write now
    /// produces a uniquely-named file.
    @Published var bridgeFileURL: URL? = nil
    /// Tracks background PDF→SVG conversion so the UI can show feedback.
    @Published var conversionStatus: ConversionStatus = .idle
    /// Tracks Inkscape installation status and all available paths.
    @Published var inkscapeStatus: InkscapeStatus = .checking
    /// Tracks Ghostscript (gs) installation status.
    @Published var ghostscriptStatus: CommandLineToolStatus = .checking
    /// Tracks MuPDF (mutool) installation status.
    @Published var mutoolStatus: CommandLineToolStatus = .checking
    /// Tracks in-progress / result state for the "Place in Keynote" action.
    @Published var keynoteSendStatus: KeynoteSendStatus = .idle
    /// When non-nil, the preview shows this PDF instead of an SVG. Set by
    /// "Pull from Keynote"; setting it clears `svgString`, and vice versa.
    @Published var previewPDFURL: URL? = nil {
        didSet {
            if previewPDFURL != nil && !svgString.isEmpty {
                svgString = ""
                svgURL = ""
            }
            if let url = previewPDFURL {
                bridgeFileURL = nil
                cachePDFMetadata(url)
                scheduleHistoryCapture()
            } else {
                pdfDimensions = nil
                pdfFileSize = ""
            }
        }
    }
    /// Tracks in-progress / result state for the "Pull from Keynote" action.
    @Published var keynotePullStatus: KeynotePullStatus = .idle
    /// The active cancellation token for an in-flight pull operation.
    /// Set by triggerKeynoteSlide/triggerKeynoteClipboard; nil when idle.
    /// ContentView observes this to wire the Escape key to cancel.
    @Published var activePullToken: PullCancellationToken? = nil
    /// Change count of the last pasteboard snapshot we acted on. Used by
    /// checkAndLoadClipboardSVG to skip re-processing an unchanged clipboard.
    var lastLoadedClipboardChangeCount: Int = -1

    /// The minimum width needed to display the button area without truncation,
    /// measured by ContentView's invisible probe during its first layout pass.
    /// MainWindowController observes this and applies it as contentMinSize.width.
    @Published var minimumButtonAreaWidth: CGFloat = 0
    /// The measured natural height of all content below the preview well.
    /// MainWindowController observes this to keep the window tall enough.
    @Published var minimumBelowPreviewHeight: CGFloat = 0

    /// The transient status/error string shown below the preview. Updated by
    /// button actions and menu commands alike. Empty means "show default state".
    @Published var statusMessage: String = ""

    /// Non-nil when the last load was rejected for being too large. Holds the
    /// raw SVG string so the user can force-load it via "Convert Large File".
    @Published var pendingOversizedSVG: (string: String, url: String?, bytes: Int)? = nil

    /// True while a large-SVG background load is in progress. Drives the
    /// Cancel button and keeps the spinner visible until WebKit finishes.
    @Published var isLoadingLargeSVG: Bool = false

    /// True when the clipboard contains Keynote-native object data (the type
    /// written by Keynote when you ⌘C canvas objects). Drives the enabled
    /// state of the "Convert Keynote Clipboard to PDF" button.
    @Published var keynoteClipboardReady: Bool = false

    /// True when Keynote is running. Drives the enabled state of the
    /// "Convert Keynote Slide to PDF" button. Does not check for open
    /// documents — the existing error message handles that case.
    @Published var keynoteRunning: Bool = false

    /// True when KeyJig has Accessibility permission. Drives the enabled state
    /// of "Place SVG in Keynote" and the visibility of the lock notice.
    @Published var accessibilityGranted: Bool = AXIsProcessTrusted()

    /// Whether macOS has granted Automation permission to send Apple Events to
    /// Keynote. nil = not yet determined (first use will prompt the user and
    /// grant automatically on approval); false = explicitly denied. Only the
    /// denied state is surfaced in Settings — nil and true need no user action.
    @Published var keynoteAutomationGranted: Bool? = nil

    /// True when a Keynote pull has been running unusually long — set by a
    /// watchdog timer in triggerKeynoteSlide/triggerKeynoteClipboard, cleared
    /// as soon as the pull completes. macOS can silently reset the Automation
    /// TCC entry (e.g. on an OS upgrade) without ever showing a consent
    /// dialog; when that happens the underlying NSAppleScript call blocks
    /// indefinitely with zero on-screen feedback. This flag is the backstop
    /// that surfaces *something* even when we can't identify the exact cause.
    @Published var keynotePullStalled: Bool = false

    /// The original clipboard PDF data that was converted to SVG via Inkscape.
    /// Retained so Option-drag can export the source PDF instead of the
    /// outlined SVG. Cleared when content arrives from a non-PDF source.
    var sourceClipboardPDFData: Data?

    /// Cached PDF rendering of the current SVG content. Populated lazily by
    /// ContentView after the WKWebView finishes loading. Used by Option-drag
    /// when no source PDF passthrough is available.
    var renderedPDFData: Data?

    /// Retains the offscreen WKWebView used by preRenderPDF until the render
    /// completes. Without a strong reference the view is deallocated before
    /// the navigation callback fires.
    var exportWebView: WKWebView?

    private var clipboardCancellable: AnyCancellable?
    private var workspaceObservers: [Any] = []
    private var appObservers: [Any] = []

    init() {
        checkInkscapeStatus()
        checkGhostscriptStatus()
        checkMutoolStatus()
        startKeynoteMonitoring()
    }

    deinit {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func startKeynoteMonitoring() {
        // ── Keynote running state ─────────────────────────────────────────
        // Seed current state, then track via workspace notifications (zero
        // polling cost).
        keynoteRunning = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.iWork.Keynote")
            .first != nil

        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                    app.bundleIdentifier == "com.apple.iWork.Keynote" else { return }
                self?.keynoteRunning = true
        })
        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                    app.bundleIdentifier == "com.apple.iWork.Keynote" else { return }
                self?.keynoteRunning = false
        })

        // ── Clipboard monitoring ──────────────────────────────────────────
        // The shared watcher polls the change count once for the whole app;
        // this subscription seeds immediately (CurrentValueSubject) and fires
        // only when the count has actually moved.
        clipboardCancellable = ClipboardWatcher.shared.changeCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.checkClipboardForKeynoteData()
            }

        // ── Accessibility + Automation grant state ────────────────────────
        // Re-check both when KeyJig comes to the foreground — the user may
        // have just toggled a permission in System Settings and switched back.
        checkKeynoteAutomationStatus()   // seed immediately
        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                let trusted = AXIsProcessTrusted()
                if self?.accessibilityGranted != trusted {
                    self?.accessibilityGranted = trusted
                }
                self?.checkKeynoteAutomationStatus()
        })
    }

    /// Checks whether macOS has granted Automation permission to control Keynote
    /// via Apple Events, without prompting the user. Uses the TCC database via
    /// AEDeterminePermissionToAutomateTarget so it works even when Keynote is
    /// not running.
    private func checkKeynoteAutomationStatus() {
        // Build an AE address descriptor for Keynote's bundle ID.
        // typeApplicationBundleID = 'bund' = 0x62756E64 — works without the
        // target app running, unlike process-ID or URL descriptors.
        guard let data = "com.apple.iWork.Keynote".data(using: .utf8),
              let desc = NSAppleEventDescriptor(descriptorType: 0x62756E64, data: data),
              let ptr = desc.aeDesc else { return }

        // typeWildCard = '****' = 0x2A2A2A2A — match any event class/ID.
        // askUserIfNeeded: false — query TCC without prompting.
        let wildcard: AEEventClass = 0x2A2A2A2A
        let status = AEDeterminePermissionToAutomateTarget(ptr, wildcard, wildcard, false)

        // noErr (0) = granted; -1743 = denied; anything else (e.g. -1744 =
        // not yet determined) is treated as nil so no warning is shown.
        let result: Bool? = status == noErr ? true : (status == -1743 ? false : nil)
        if keynoteAutomationGranted != result {
            keynoteAutomationGranted = result
        }
    }

    /// Actively requests Automation permission to control Keynote, prompting
    /// the user with the system consent dialog if macOS hasn't decided yet.
    /// Must be called off the main thread — the call blocks until the user
    /// answers the dialog (or returns immediately if already decided).
    ///
    /// checkKeynoteAutomationStatus() above always passes askUserIfNeeded:
    /// false, so it only ever *reads* the TCC state — it never causes macOS
    /// to show the consent dialog. If the TCC entry has been reset (observed
    /// after an OS upgrade) and nothing ever asks with askUserIfNeeded: true,
    /// the entry stays undecided forever and every subsequent NSAppleScript
    /// send to Keynote blocks silently with no dialog and no error. Call this
    /// once at the start of each pull, before the first real Apple Event.
    func requestKeynoteAutomationPermission() -> Bool {
        guard let data = "com.apple.iWork.Keynote".data(using: .utf8),
              let desc = NSAppleEventDescriptor(descriptorType: 0x62756E64, data: data),
              let ptr = desc.aeDesc else { return true }

        let wildcard: AEEventClass = 0x2A2A2A2A
        let status = AEDeterminePermissionToAutomateTarget(ptr, wildcard, wildcard, true)
        let granted = status == noErr
        let result: Bool? = granted ? true : (status == -1743 ? false : nil)
        DispatchQueue.main.async { [weak self] in
            if self?.keynoteAutomationGranted != result {
                self?.keynoteAutomationGranted = result
            }
        }
        return granted
    }

    // MARK: - Content history (⌘[ / ⌘] navigation)

    /// One unit of canvas content — either an SVG (string in memory) or a
    /// pulled-from-Keynote PDF (temp file URL). Mirrors the fields that
    /// clearContent snapshots for undo.
    struct ContentSnapshot: Equatable {
        let svgString: String
        let svgURL: String
        let bridgeFileURL: URL?
        let previewPDFURL: URL?
        let conversionStatus: ConversionStatus

        var isEmpty: Bool { svgString.isEmpty && previewPDFURL == nil }
        /// SVG strings live in memory; PDF entries only hold a URL.
        var costInBytes: Int { svgString.utf8.count }
        /// A PDF entry goes stale if its temp file has been cleaned up.
        var isStillValid: Bool {
            guard let pdf = previewPDFURL else { return true }
            return FileManager.default.fileExists(atPath: pdf.path)
        }
    }

    /// Browser-style history: entries up to historyCursor are "back",
    /// entries after it are "forward". Loading new content truncates the
    /// forward tail. Deliberately small — the goal is "get back that thing
    /// from a minute ago", not an archive.
    private var historyEntries: [ContentSnapshot] = []
    private var historyCursor: Int = -1
    /// Set while goBack/goForward (or undo) rewrites content, so the didSet
    /// hooks don't record the restoration as a fresh visit.
    private var isRestoringContent = false
    private var historyCaptureScheduled = false
    private let maxHistoryEntries = 10
    private let maxHistoryBytes = 20 * 1024 * 1024

    /// Coalesces history capture to the end of the current run-loop turn.
    /// Content loads set several properties in sequence (svgString, then
    /// svgURL, …); deferring the snapshot captures them as one unit.
    private func scheduleHistoryCapture() {
        guard !isRestoringContent, !historyCaptureScheduled else { return }
        historyCaptureScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.historyCaptureScheduled = false
            self.captureHistorySnapshot()
        }
    }

    private var currentSnapshot: ContentSnapshot {
        ContentSnapshot(
            svgString: svgString, svgURL: svgURL, bridgeFileURL: bridgeFileURL,
            previewPDFURL: previewPDFURL, conversionStatus: conversionStatus)
    }

    /// True when the canvas still shows the entry at the cursor (i.e. the
    /// user hasn't cleared it since). Content comparison is cheap relative
    /// to how rarely this runs (menu validation, ⌘[ / ⌘] presses).
    private var currentMatchesCursor: Bool {
        historyEntries.indices.contains(historyCursor)
            && historyEntries[historyCursor] == currentSnapshot
    }

    private func captureHistorySnapshot() {
        let snap = currentSnapshot
        guard !snap.isEmpty, !currentMatchesCursor else { return }
        // New content truncates any forward entries (browser semantics).
        historyEntries.removeSubrange((historyCursor + 1)...)
        historyEntries.append(snap)
        historyCursor = historyEntries.count - 1
        // Trim oldest-first to the entry and byte caps, but never the entry
        // just added.
        while historyEntries.count > 1,
            historyEntries.count > maxHistoryEntries
                || historyEntries.reduce(0, { $0 + $1.costInBytes }) > maxHistoryBytes
        {
            historyEntries.removeFirst()
            historyCursor -= 1
        }
    }

    /// Back is available when there's an older entry — or when the canvas
    /// was cleared, in which case ⌘[ re-opens the entry at the cursor.
    var canGoBack: Bool {
        historyCursor > 0 || (historyCursor == 0 && !currentMatchesCursor)
    }

    var canGoForward: Bool { historyCursor < historyEntries.count - 1 }

    func goBack() {
        guard canGoBack else { return }
        if currentMatchesCursor { historyCursor -= 1 }
        restoreHistoryEntry()
    }

    func goForward() {
        guard canGoForward else { return }
        historyCursor += 1
        restoreHistoryEntry()
    }

    private func restoreHistoryEntry() {
        // Drop entries whose temp PDF has vanished, sliding the cursor left.
        while historyEntries.indices.contains(historyCursor),
            !historyEntries[historyCursor].isStillValid
        {
            historyEntries.remove(at: historyCursor)
            historyCursor -= 1
        }
        guard historyEntries.indices.contains(historyCursor) else { return }
        isRestoringContent = true
        defer { isRestoringContent = false }
        applySnapshot(historyEntries[historyCursor])
    }

    /// Writes a snapshot back to the canvas, using the setters that keep
    /// svgString and previewPDFURL mutually exclusive (each didSet clears
    /// the other).
    private func applySnapshot(_ snap: ContentSnapshot) {
        sourceClipboardPDFData = nil
        log.info("applySnapshot: cleared sourceClipboardPDFData")
        if let pdf = snap.previewPDFURL {
            previewPDFURL = pdf
        } else {
            svgString = snap.svgString
            svgURL = snap.svgURL
            bridgeFileURL = snap.bridgeFileURL
            conversionStatus = snap.conversionStatus
        }
        statusMessage = ""
    }

    /// Clears whichever content mode is currently active (SVG or pulled PDF).
    /// Every deletion path — trash button, Delete keys, Edit ▸ Clear, context
    /// menu, AppleScript `clear` — funnels through here.
    ///
    /// Registers the clear with the given undo manager so ⌘Z reverses it
    /// (and ⇧⌘Z re-clears). Undo/redo is for the destructive act; ⌘[ / ⌘]
    /// history navigation is independent of it.
    func clearContent(registeringWith undoManager: UndoManager?) {
        let snap = currentSnapshot
        if !snap.isEmpty {
            undoManager?.registerUndo(withTarget: self) {
                [weak undoManager] state in
                state.undoClear(restoring: snap, undoManager: undoManager)
            }
            undoManager?.setActionName(NSLocalizedString(
                "undo.clear",
                comment: "Undo action name shown in Edit menu after clearing the canvas"))
        }

        if previewPDFURL != nil {
            previewPDFURL = nil
            bridgeFileURL = nil
        } else {
            svgString = ""
            svgURL = ""
            bridgeFileURL = nil
            conversionStatus = .idle
        }
        sourceClipboardPDFData = nil
        log.info("clearContent: cleared sourceClipboardPDFData")
        statusMessage = ""
    }

    /// Undo of a clear: restore the snapshot and register the inverse so
    /// redo re-clears. The restored content is already at the history
    /// cursor, so the capture hooks dedupe it — no duplicate entry.
    private func undoClear(restoring snap: ContentSnapshot, undoManager: UndoManager?) {
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] state in
            state.clearContent(registeringWith: undoManager)
        }
        applySnapshot(snap)
    }

    private func checkClipboardForKeynoteData() {
        let pb = NSPasteboard.general
        // Keynote writes types containing "keynote" or "iWork" when canvas
        // objects are copied. This excludes plain PDFs, images, and text that
        // other apps write — those don't round-trip as native vector objects.
        let ready = (pb.types ?? []).contains { t in
            t.rawValue.localizedCaseInsensitiveContains("keynote") ||
            t.rawValue.localizedCaseInsensitiveContains("iWork")
        }
        if keynoteClipboardReady != ready {
            keynoteClipboardReady = ready
        }
    }

    private func checkInkscapeStatus() {
        DispatchQueue.global(qos: .userInitiated).async {
            let paths = allInkscapeURLs().map(\.path)
            DispatchQueue.main.async {
                if paths.isEmpty {
                    self.inkscapeStatus = .notInstalled
                } else {
                    self.inkscapeStatus = .installed(paths: paths)
                }
            }
        }
    }

    private func checkGhostscriptStatus() {
        DispatchQueue.global(qos: .userInitiated).async {
            let url = ghostscriptURL()
            DispatchQueue.main.async {
                self.ghostscriptStatus = url.map { .installed(path: $0.path) } ?? .notInstalled
            }
        }
    }

    private func checkMutoolStatus() {
        DispatchQueue.global(qos: .userInitiated).async {
            let url = mutoolURL()
            DispatchQueue.main.async {
                self.mutoolStatus = url.map { .installed(path: $0.path) } ?? .notInstalled
            }
        }
    }

    private func cachePDFMetadata(_ url: URL) {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB]
        formatter.countStyle = .file
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let bytes = attrs[.size] as? Int64 {
            pdfFileSize = formatter.string(fromByteCount: bytes)
        } else {
            pdfFileSize = ""
        }
        if let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1) {
            let box = page.getBoxRect(.mediaBox)
            pdfDimensions = (width: Double(box.width), height: Double(box.height))
        } else {
            pdfDimensions = nil
        }
    }
}

// MARK: - Supporting Types

enum ConversionStatus: Equatable {
    case idle
    case converting
    case failed
    case emptyOnInitialLoad
}

enum KeynoteSendStatus: Equatable {
    case idle
    case sending
    case succeeded
    case failed
}

enum KeynotePullStatus: Equatable {
    case idle
    case pulling
    case succeeded
    case failed
}

enum InkscapeStatus: Equatable {
    case checking
    case installed(paths: [String])  // All found installations
    case notInstalled
}

/// Status of a single-path command-line tool (Ghostscript, MuPDF).
enum CommandLineToolStatus: Equatable {
    case checking
    case installed(path: String)
    case notInstalled
}

