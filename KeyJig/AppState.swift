import Combine
import Foundation
import SwiftUI
import AppKit

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
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let count = NSPasteboard.general.changeCount
            if count != self.changeCount.value {
                self.changeCount.send(count)
            }
        }
        timer.tolerance = 0.1
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
            } else {
                svgDimensions = extractSVGDimensions(svgString: svgString)
                svgFileSize = getFileSizeString(svgString: svgString)
                svgCreator = extractSVGCreator(svgString: svgString)
            }
        }
    }
    /// Cached result of extractSVGDimensions — updated whenever svgString changes.
    private(set) var svgDimensions: (width: Double, height: Double)? = nil
    /// Cached result of getFileSizeString — updated whenever svgString changes.
    private(set) var svgFileSize: String = ""
    /// Cached result of extractSVGCreator — updated whenever svgString changes.
    private(set) var svgCreator: String? = nil
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
}

// MARK: - Supporting Types

enum ConversionStatus: Equatable {
    case idle
    case converting
    case failed
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

