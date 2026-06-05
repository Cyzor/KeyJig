import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import os

private let log = Logger(subsystem: "com.cyzor.KeyJig", category: "ContentView")
private let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

// MARK: - Responsive SVG renderer

/// A WKWebView-backed renderer that scales the SVG to fill its frame while
/// preserving aspect ratio. The HTML wrapper in `wrapSVGForResponsiveDisplay`
/// (see `SVGProcessing.swift`) supplies the CSS reset and `position: fixed`
/// trick that makes `height: 100%` actually fill the viewport.
struct ResponsiveSVGWebView: NSViewRepresentable {

    let svg: String
    var onWebViewLoad: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let prefs = WKPreferences()
        let config = WKWebViewConfiguration()
        config.preferences = prefs
        let pagePrefs = WKWebpagePreferences()
        pagePrefs.preferredContentMode = .desktop
        pagePrefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = pagePrefs
        config.allowsAirPlayForMediaPlayback = false

        let webView = WKWebView(frame: .zero, configuration: config)
        // Prevent WebKit's native layer from painting a white background behind
        // the transparent HTML. Private KVC — guarded so a future removal
        // degrades to a white preview rather than a crash.
        if webView.responds(to: Selector(("setDrawsBackground:"))) {
            webView.setValue(false, forKey: "drawsBackground")
        }

        webView.navigationDelegate = context.coordinator
        context.coordinator.onWebViewLoad = onWebViewLoad

        let html = wrapSVGForResponsiveDisplay(svgString: svg)
        context.coordinator.lastSVG = svg
        webView.loadHTMLString(html, baseURL: nil)
        resetViewport(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onWebViewLoad = onWebViewLoad
        guard svg != context.coordinator.lastSVG else { return }
        context.coordinator.lastSVG = svg
        let html = wrapSVGForResponsiveDisplay(svgString: svg)
        webView.loadHTMLString(html, baseURL: nil)
        resetViewport(webView)
    }

    /// Forces WebKit to recalculate vh/vw from the view's current bounds.
    /// Without this, stale layout-viewport dimensions from the previous load
    /// cause 100vh/100vw to resolve to the wrong size on subsequent reloads.
    private func resetViewport(_ webView: WKWebView) {
        DispatchQueue.main.async {
            let frame = webView.frame
            webView.frame = .zero
            webView.frame = frame
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var lastSVG: String = ""
        var onWebViewLoad: (() -> Void)?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onWebViewLoad?()
        }
    }
}

// MARK: - PDF preview

/// PDFKit-backed renderer for the "Pull from Keynote" result. Auto-scales the
/// page to fit the view, scroll/zoom disabled — interaction goes through the
/// SVGInteractionView overlay (drag-out, drop-replace).
struct PDFPreviewView: NSViewRepresentable {

    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.backgroundColor = .clear
        // Disable the built-in scroll/scale gestures so the overlay handles
        // mouse events cleanly.
        view.acceptsDraggedFiles = false
        if let scrollView = view.subviews.first as? NSScrollView {
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.scrollerStyle = .overlay
        }
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}

// MARK: - Metadata overlay

struct MetadataOverlay: View {
    let dimensions: (width: Double, height: Double)?
    let fileSize: String
    let creator: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let (width, height) = dimensions {
                MetadataRow(
                    label: NSLocalizedString(
                        "metadata.dimensions",
                        comment: "Metadata overlay label for SVG width × height"),
                    value: "\(Int(width.rounded())) × \(Int(height.rounded()))"
                )
            }
            MetadataRow(
                label: NSLocalizedString(
                    "metadata.size",
                    comment: "Metadata overlay label for SVG file size"),
                value: fileSize)
            if let creator {
                MetadataRow(
                    label: NSLocalizedString(
                        "metadata.source",
                        comment: "Metadata overlay label for the SVG creator application"),
                    value: creator)
            }
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.75))
        .cornerRadius(6)
        .frame(maxWidth: 200)
    }
}

struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .frame(width: 65, alignment: .trailing)
            Text(":")
                .padding(.horizontal, 3)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
        }
    }
}

// MARK: - Option-key monitor

/// Tracks whether the Option key is currently held down.
/// One instance per ContentView so each window gets its own local monitor.
/// Local monitors fire only while the app is key — no cross-app leakage.
private class OptionKeyMonitor: ObservableObject {
    @Published var isHeld = false
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags
            self?.isHeld = flags.contains(.option) || flags.contains(.shift)
            return event
        }
    }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }
}

// MARK: - Main content view

struct ContentView: View {
    @ObservedObject var appState: AppState
    /// True when this ContentView is hosted inside the menu-bar popover.
    /// Suppresses keyboard-shortcut labels and the Option-key reveal —
    /// the popover can't reliably receive ⌘ shortcuts without explicit focus.
    /// Kept here rather than on AppState so the same AppState can be shared
    /// between a floating window and the popover without affecting either's UI.
    let isPopoverContext: Bool
    /// True when this ContentView is hosted inside the menu-bar popover,
    /// regardless of whether it is mirroring a document window. Used only for
    /// drop routing — multi-file drops send all results to new floating windows
    /// rather than loading the first into the popover's (or mirrored window's)
    /// AppState. Distinct from `isPopoverContext`, which controls keyboard
    /// shortcut visibility and the option-reveal.
    let isPopoverSurface: Bool
    @StateObject private var optionMonitor = OptionKeyMonitor()
    @Environment(\.undoManager) private var undoManager
    @State private var svgPopReady = false
    @State private var pdfPopReady = false
    // Status messages are stored in appState.statusMessage so menu commands
    // (which route through AppDelegate) can update the same property.
    init(appState: AppState = AppState(), isPopoverContext: Bool = false, isPopoverSurface: Bool = false) {
        self.appState = appState
        self.isPopoverContext = isPopoverContext
        self.isPopoverSurface = isPopoverSurface
    }

    private static let breakApartInstruction = NSLocalizedString(
        "instruction.break_apart",
        comment:
            "Instruction shown below the status area directing user to use Keynote's Break Apart")

    /// Spoken description of the loaded SVG for VoiceOver. WKWebView itself
    /// exposes no useful accessibility tree for SVG content, so we synthesise
    /// one from the metadata we already extract.
    var svgPreviewAccessibilityLabel: String {
        let format = NSLocalizedString(
            "accessibility.svg_preview",
            comment: "VoiceOver label for the loaded SVG preview, e.g. 'SVG preview, 512 by 384, 23.4 KB'")
        let dims: String
        if let (w, h) = appState.svgDimensions {
            dims = "\(Int(w.rounded())) × \(Int(h.rounded()))"
        } else {
            dims = "—"
        }
        let size = appState.svgFileSize
        return String.localizedStringWithFormat(format, dims, size)
    }

    /// True when either an SVG or a pulled PDF is loaded into the preview.
    private var hasContent: Bool {
        !appState.svgString.isEmpty || appState.previewPDFURL != nil
    }

    /// True when the empty well is showing its own built-in spinner.
    /// Used to suppress the redundant status-area entry for the same operation.
    private var isEmptyWellProcessing: Bool {
        !hasContent && (appState.conversionStatus == .converting
            || appState.keynotePullStatus == .pulling)
    }

    /// True when the preview holds a PDF pulled from Keynote.
    private var isPDFMode: Bool {
        appState.previewPDFURL != nil
    }

    /// Routes one or more dropped SVGs to the right destination.
    /// In a regular window the first SVG loads here; extras open new floating
    /// windows. On the popover surface (isPopoverSurface), multi-file drops
    /// send every result to a new floating window so the pinned panel isn't
    /// commandeered and the mirrored window isn't silently overwritten;
    /// single-file drops still load into the popover normally.
    private func handleDroppedSVGs(_ svgs: [String]) {
        guard let first = svgs.first else { return }
        if isPopoverSurface && svgs.count > 1 {
            // Multi-file on the popover: every result gets its own floating window
            // so the pinned panel isn't commandeered and the mirrored window isn't
            // silently overwritten. Single files still load into the popover normally.
            for svg in svgs {
                AppDelegate.shared?.openNewFloatingWindow(withSVG: svg)
            }
        } else {
            appState.conversionStatus = .idle
            appState.svgString = first
            appState.statusMessage = ""
            for svg in svgs.dropFirst() {
                AppDelegate.shared?.openNewFloatingWindow(withSVG: svg)
            }
        }
    }

    var computedStatusMessage: String {
        switch appState.conversionStatus {
        case .converting:
            return NSLocalizedString(
                "status.converting",
                comment: "Status: Inkscape conversion is in progress")
        case .failed:
            return NSLocalizedString(
                "status.failed",
                comment: "Status: conversion found no usable data")
        case .idle:
            break
        }
        if appState.keynotePullStatus == .pulling {
            return NSLocalizedString(
                "status.keynote.pulling",
                comment: "Status: Keynote export is in progress")
        }
        let base: String
        if !appState.statusMessage.isEmpty {
            base = appState.statusMessage
        } else if hasContent && !isPDFMode {
            base = NSLocalizedString(
                "status.ready",
                comment: "Status: SVG is loaded and ready to use")
        } else if hasContent && isPDFMode {
            base = NSLocalizedString(
                "status.keynote.pulled",
                comment: "Status: PDF was pulled from Keynote successfully")
        } else {
            return ""
        }
        // The Break Apart hint only applies to SVG content destined for Keynote.
        return (hasContent && !isPDFMode) ? base + "\n\n" + Self.breakApartInstruction : base
    }

    /// Clears whichever content mode is currently active and registers an undo
    /// operation so ⌘Z can restore the content.
    private func clearCanvas() {
        // Snapshot the current state before modifying anything.
        let prevSVG       = appState.svgString
        let prevURL       = appState.svgURL
        let prevBridge    = appState.bridgeFileURL
        let prevPDF       = appState.previewPDFURL
        let prevStatus    = appState.conversionStatus

        undoManager?.registerUndo(withTarget: appState) { state in
            // Restore — use the setters that keep svgString and previewPDFURL
            // mutually exclusive (each didSet clears the other).
            if prevPDF != nil {
                state.previewPDFURL = prevPDF
            } else {
                state.svgString     = prevSVG
                state.svgURL        = prevURL
                state.bridgeFileURL = prevBridge
                state.conversionStatus = prevStatus
            }
            // Leave statusMessage empty after undo — the restored content sets
            // its own default via computedStatusMessage.
        }
        undoManager?.setActionName(NSLocalizedString(
            "undo.clear",
            comment: "Undo action name shown in Edit menu after clearing the canvas"))

        if isPDFMode {
            appState.previewPDFURL = nil
        } else {
            appState.svgString = ""
            appState.svgURL = ""
            appState.bridgeFileURL = nil
            appState.conversionStatus = .idle
        }
        appState.statusMessage = ""
    }

    var body: some View {
        VStack(spacing: 4) {

            // ── Preview / drop well ───────────────────────────────────────
            Group {
                if let pdfURL = appState.previewPDFURL {
                    loadedPDFPreview(url: pdfURL)
                } else if !appState.svgString.isEmpty {
                    loadedPreview
                } else {
                    emptyWell
                }
            }
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .padding([.horizontal, .top])
            .frame(minHeight: 200, maxHeight: .infinity)
            .accessibilityIdentifier("preview_drop_well")

            VStack(spacing: 4) {

            if isPDFMode {
                // ── PDF done state ────────────────────────────────────────
                // The result is already in the preview well — just tell the
                // user to drag it. No buttons needed; they imply work remains.
                Text(NSLocalizedString(
                    "hint.pdf_done",
                    comment: "Muted prompt shown below the preview when a Keynote PDF result is in the well"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
            } else {

            // ── Status ────────────────────────────────────────────────────
            if !computedStatusMessage.isEmpty && !isEmptyWellProcessing {
                HStack(spacing: 6) {
                    if appState.conversionStatus == .converting
                        || appState.keynotePullStatus == .pulling
                        || appState.keynoteSendStatus == .sending {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                    }
                    Text(computedStatusMessage)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundColor(
                            appState.conversionStatus == .failed ? .red : .secondary
                        )
                        .accessibilityLabel(computedStatusMessage)
                        .accessibilityAddTraits(.updatesFrequently)
                        .accessibilityIdentifier("status_message")
                        .onChange(of: computedStatusMessage) { newValue in
                            announceToVoiceOver(newValue)
                        }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .frame(minHeight: 50, alignment: .top)
                .help(appState.svgString.isEmpty ? "" : Tooltips.readyStatus)
            }

            // ── Accessibility notice ──────────────────────────────────────
            // Shown in SVG mode only (svgString non-empty ↔ ⌘D is visible).
            // In PDF mode svgString is empty, so the notice is naturally hidden.
            if !appState.accessibilityGranted && !appState.svgString.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text(NSLocalizedString(
                        "accessibility.keynote_notice",
                        comment: "Accessibility notice: access required for Keynote interactions"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(NSLocalizedString(
                        "settings.accessibility.open_settings",
                        comment: "Button: open System Settings to grant accessibility")) {
                        NSWorkspace.shared.open(accessibilitySettingsURL)
                    }
                    .font(.caption)
                    .help(NSLocalizedString(
                        "tooltip.settings.accessibility_open",
                        comment: "Tooltip for accessibility settings button"))
                }
                .padding(.horizontal)
                .padding(.bottom, 6)
            }

            Divider().padding(.vertical, 8)

            // ── Action buttons ────────────────────────────────────────────
            let isConverting = appState.conversionStatus == .converting
            let isPulling = appState.keynotePullStatus == .pulling
            VStack(spacing: 8) {
                // ── Convert Keynote Slide  ⌘R  ────────────────────────────
                // ── Convert Keynote Selection  ⌘E ────────────────────────
                // Hidden by default; revealed while Option is held. Menu
                // shortcuts remain available at all times regardless. The
                // Option reveal keeps the default view focused on the
                // SVG-import workflow while giving power users easy access.
                if optionMonitor.isHeld && !isPopoverContext {
                    // ── Convert Keynote Slide  ⌘R ─────────────────────────
                    Button {
                        triggerKeynoteSlide(appState: appState) { appState.statusMessage = $0 }
                    } label: {
                        Label {
                            buttonRow(
                                NSLocalizedString("button.pull_from_keynote",
                                    comment: "Button: converts the current Keynote slide to a vector PDF"),
                                shortcut: "⌘R",
                                showShortcut: !isPopoverContext)
                        } icon: {
                            Image(systemName: "document.badge.ellipsis.fill")
                                .font(.system(size: 20))
                                .padding(.leading, 4)
                        }
                        .padding(.vertical, 6)
                    }
                    .help(Tooltips.pullFromKeynote)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(isConverting || isPulling || !appState.keynoteRunning)

                    // ── Convert Keynote Clipboard to PDF ⌘E ────────────────────
                    VStack(alignment: .leading, spacing: 2) {
                        Button {
                            triggerKeynoteClipboard(appState: appState) { appState.statusMessage = $0 }
                        } label: {
                            Label {
                                buttonRow(
                                    NSLocalizedString("button.import_selection_from_keynote",
                                        comment: "Button: converts the user's copied Keynote clipboard to a vector PDF"),
                                    shortcut: "⌘E",
                                    showShortcut: !isPopoverContext)
                            } icon: {
                                Image(systemName: "rectangle.dashed")
                                    .font(.system(size: 20))
                            }
                            .padding(.vertical, 6)
                        }
                        .help(Tooltips.importSelectionFromKeynote)
                        .keyboardShortcut("e", modifiers: .command)
                        .disabled(isConverting || isPulling || !appState.keynoteRunning || !appState.keynoteClipboardReady)

                        // Live clipboard readiness indicator
                        if appState.keynoteRunning {
                            HStack(spacing: 4) {
                                if appState.keynoteClipboardReady {
                                    Image(systemName: "checkmark.circle.fill")
                                    Text(NSLocalizedString(
                                        "hint.keynote.clipboard_ready",
                                        comment: "Hint: Keynote selection is on the clipboard"))
                                } else {
                                    Text(NSLocalizedString(
                                        "hint.keynote.clipboard_not_ready",
                                        comment: "Hint: no Keynote selection on the clipboard yet"))
                                }
                            }
                            .font(.caption2)
                            .foregroundColor(appState.keynoteClipboardReady ? .accentColor : .secondary)
                            .padding(.leading, 40)
                            .padding(.top, 6)
                            .animation(.easeInOut(duration: 0.15), value: appState.keynoteClipboardReady)
                        }
                    }
                }

                // ── Place in Keynote  ⌘D ─────────────────────────────────
                let isSending = appState.keynoteSendStatus == .sending
                Button {
                    appState.keynoteSendStatus = .sending
                    appState.statusMessage = NSLocalizedString(
                        "status.keynote.sending",
                        comment: "Status: SVG is being placed into Keynote")
                    sendSVGToKeynote(svgData: appState.svgString) { error in
                        if let error = error {
                            appState.keynoteSendStatus = .failed
                            appState.statusMessage = error.localizedDescription
                        } else {
                            appState.keynoteSendStatus = .succeeded
                            appState.statusMessage = NSLocalizedString(
                                "status.keynote.success",
                                comment: "Status: SVG was placed in Keynote successfully")
                        }
                    }
                } label: {
                    Label {
                        buttonRow(
                            appState.svgString.isEmpty
                                ? NSLocalizedString("button.place_in_keynote",
                                    comment: "Button: fallback label when no SVG is loaded")
                                : NSLocalizedString("button.place_svg_in_keynote",
                                    comment: "Button: places the loaded SVG directly into the current Keynote slide"),
                            shortcut: "⌘D",
                            showShortcut: !isPopoverContext)
                    } icon: {
                        Image(systemName: "arrow.down.square.fill")
                            .font(.system(size: 20))
                            .padding(.leading, 2)
                    }
                    .padding(.vertical, 6)
                }
                .help(Tooltips.placeInKeynote)
                .keyboardShortcut("d", modifiers: .command)
                .disabled(appState.svgString.isEmpty || isConverting || isSending || !appState.accessibilityGranted)

            }
            .background(
                // Invisible probe: all four button rows at their natural (ideal) width.
                // fixedSize() prevents SwiftUI from expanding them to fill the VStack;
                // the widest row wins via ButtonAreaMinWidthKey's reduce function.
                // Placed on the inner VStack (before outer padding) so the reported
                // width is just the button content — the window controller adds padding.
                VStack(spacing: 0) {
                    buttonRow(NSLocalizedString("button.pull_from_keynote",              comment: ""), shortcut: "⌘R")
                    buttonRow(NSLocalizedString("button.import_selection_from_keynote",  comment: ""), shortcut: "⌘E")
                    buttonRow(NSLocalizedString("button.place_svg_in_keynote",           comment: ""), shortcut: "⌘D")
                }
                .fixedSize()
                .hidden()
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ButtonAreaMinWidthKey.self,
                                           value: geo.size.width)
                })
            )
            .onPreferenceChange(ButtonAreaMinWidthKey.self) { width in
                guard width > 0 else { return }
                appState.minimumButtonAreaWidth = width
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)

            }   // end else (non-PDF mode)
            }   // end below-preview VStack
            .background(GeometryReader { geo in
                Color.clear.preference(key: BelowPreviewHeightKey.self,
                                       value: geo.size.height)
            })
            .onPreferenceChange(BelowPreviewHeightKey.self) { height in
                guard height > 0 else { return }
                appState.minimumBelowPreviewHeight = height
            }

        }
        // Hidden utility buttons — keyboard shortcuts with no visible affordance.
        .background(
            Group {
                // Delete / ⌘Delete clear the canvas (same as the trash icon).
                if hasContent {
                    Button("") { clearCanvas() }.keyboardShortcut(.delete, modifiers: [])
                    Button("") { clearCanvas() }.keyboardShortcut(.delete, modifiers: .command)
                }
                // Escape cancels an active pull/send operation when one is in
                // flight; otherwise it dismisses the menu-bar popover (if shown).
                Button("") {
                    if let token = appState.activePullToken, !token.isCancelled {
                        token.cancel()
                    } else if isPopoverContext {
                        AppDelegate.shared?.closePopover()
                    }
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .frame(width: 0, height: 0)
            .hidden()
        )
        .onChange(of: appState.svgString) { newValue in
            if newValue.isEmpty { svgPopReady = false }
        }
        .onChange(of: appState.previewPDFURL) { newURL in
            if newURL == nil { pdfPopReady = false }
        }
    }

    // MARK: Sub-views — preview wells

    /// Shown when a PDF was pulled from Keynote. Drag-out delivers the PDF;
    /// dropping an SVG switches back to SVG mode automatically.
    private func loadedPDFPreview(url: URL) -> some View {
        ZStack {
            CheckerboardPattern()

            PDFPreviewView(url: url)
                .padding(8)
                .scaleEffect(pdfPopReady ? 1 : 0.6)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.25)) { pdfPopReady = true }
                }

            SVGInteractionViewWrapper(
                onDragStart: { url },
                onMultiFileDropStarted: {
                    if !isPopoverSurface { appState.conversionStatus = .converting }
                },
                onSVGDropped: { svgs in
                    handleDroppedSVGs(svgs)
                },
                onClear: { clearCanvas() },
                dragLabel: NSLocalizedString(
                    "preview.drag_label_pdf",
                    comment: "Text on the drag image thumbnail when dragging a pulled PDF")
            )

            Color(NSColor.windowBackgroundColor)
                .opacity(pdfPopReady ? 0 : 1)
                .allowsHitTesting(false)
        }
        .help(Tooltips.previewPDFLoaded)
    }

    /// Shown when an SVG is loaded: renders the graphic and supports both
    /// outbound drag to Keynote and inbound replacement drops.
    private var loadedPreview: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)

            ResponsiveSVGWebView(svg: appState.svgString, onWebViewLoad: {
                guard !svgPopReady else { return }
                withAnimation(.easeOut(duration: 0.25)) { svgPopReady = true }
            })
            .scaleEffect(svgPopReady ? 1 : 0.6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(svgPreviewAccessibilityLabel)

            // Single interaction layer — handles outbound drag, inbound drop,
            // and right-click menu with no Z-order conflict.
            SVGInteractionViewWrapper(
                onDragStart: { [weak appState] in
                    guard let svg = appState?.svgString else { return nil }
                    // Reject oversized SVG before writing temp file
                    guard svg.utf8.count <= maxSVGBytes else {
                        log.error("dropped SVG exceeds size limit of \(maxSVGBytes, privacy: .public) bytes")
                        return nil
                    }
                    let url = makeTempSVGURL()
                    do {
                        try svg.write(to: url, atomically: true, encoding: .utf8)
                        // Hardened permissions: owner read/write only (0600)
                        try FileManager.default.setAttributes(
                            [.posixPermissions: 0o600],
                            ofItemAtPath: url.path
                        )
                        appState?.bridgeFileURL = url
                    } catch {
                        log.error("error writing temp SVG: \(error.localizedDescription, privacy: .public)")
                        return nil
                    }
                    return url
                },
                onMultiFileDropStarted: {
                    if !isPopoverSurface { appState.conversionStatus = .converting }
                },
                onSVGDropped: { svgs in
                    handleDroppedSVGs(svgs)
                },
                onCopyForKeynote: {
                    if svgToClipboard(svgData: appState.svgString, appState: appState) != nil {
                        appState.statusMessage = NSLocalizedString(
                            "status.copied",
                            comment:
                                "Confirmation shown after copying to clipboard via context menu")
                    }
                },
                onClear: { clearCanvas() }
            )

            // Metadata badge lower-left — no hit testing so events reach the layer below.
            VStack {
                Spacer()
                HStack {
                    MetadataOverlay(
                        dimensions: appState.svgDimensions,
                        fileSize: appState.svgFileSize,
                        creator: appState.svgCreator)
                        .padding(8)
                    Spacer()
                }
            }
            .allowsHitTesting(false)

            // Pop-in reveal: solid veil that fades away once the WebView has rendered.
            // Opacity animation on NSViewRepresentable composites against white and breaks
            // transparency; fading an opaque overlay instead avoids that entirely.
            Color(NSColor.windowBackgroundColor)
                .opacity(svgPopReady ? 0 : 1)
                .allowsHitTesting(false)
        }
        .help(Tooltips.previewAreaLoaded)
        .onReceive(appState.$svgString) { newValue in
            // When content arrives externally (clipboard detection, drop),
            // clear any stale local status so the computed computedStatusMessage shows.
            if !newValue.isEmpty {
                appState.statusMessage = ""
            }
        }
    }

    /// Shown when no SVG is loaded: drop target only, no drag source or menu.
    private var emptyWell: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)

            // Interaction layer (drop only — onDragStart and menu callbacks are nil).
            SVGInteractionViewWrapper(
                onMultiFileDropStarted: {
                    if !isPopoverSurface { appState.conversionStatus = .converting }
                },
                onSVGDropped: { svgs in
                    handleDroppedSVGs(svgs)
                }
            )

            // Visual prompt — no hit testing so drops reach the layer below.
            if isEmptyWellProcessing {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text(computedStatusMessage)
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .allowsHitTesting(false)
            } else {
                VStack(spacing: 12) {
                    Image("Placeholder")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)
                        .foregroundColor(.secondary)
                        .accessibilityLabel(
                            NSLocalizedString(
                                "accessibility.placeholder_icon",
                                comment: "VoiceOver label for the empty state illustration"
                            ))

                    Text(
                        NSLocalizedString(
                            "empty_state.title",
                            comment: "Empty state heading when no SVG is loaded")
                    )
                    .font(.headline)
                    .foregroundColor(.secondary)

                    Text(
                        NSLocalizedString(
                            "empty_state.body",
                            comment: "Empty state instructions when no SVG is loaded")
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                }
                .allowsHitTesting(false)
            }
        }
        .help(Tooltips.previewAreaEmpty)
    }
}

// MARK: - VoiceOver

/// Posts a polite announcement so VoiceOver users hear status changes
/// (e.g. "Copied to clipboard", "Conversion failed") without having to
/// navigate back to the status text.
func announceToVoiceOver(_ message: String) {
    guard !message.isEmpty else { return }
    let target: Any = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp as Any
    NSAccessibility.post(
        element: target,
        notification: .announcementRequested,
        userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ]
    )
}

// MARK: - Checkerboard background

/// Subtle checkerboard rendered as an NSView; adapts to dark/light mode.
/// Used in content-loaded preview wells so white artwork doesn't disappear
/// into a white background.
private struct CheckerboardPattern: NSViewRepresentable {
    func makeNSView(context: Context) -> CheckerboardNSView { CheckerboardNSView() }
    func updateNSView(_ view: CheckerboardNSView, context: Context) {}
}

private class CheckerboardNSView: NSView {
    private let tile: CGFloat = 10

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let a = isDark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 1.00, alpha: 1)
        let b = isDark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.91, alpha: 1)
        let minCol = Int(floor(dirtyRect.minX / tile))
        let maxCol = Int(ceil(dirtyRect.maxX  / tile))
        let minRow = Int(floor(dirtyRect.minY / tile))
        let maxRow = Int(ceil(dirtyRect.maxY  / tile))
        for row in minRow ..< maxRow {
            for col in minCol ..< maxCol {
                ((row + col) % 2 == 0 ? a : b).setFill()
                NSRect(x: CGFloat(col) * tile, y: CGFloat(row) * tile,
                       width: tile, height: tile).fill()
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Minimum button area width preference

/// Collects the maximum natural (unconstrained) width of any button row.
/// MainWindowController observes this via AppState and applies it as the
/// window's content minimum width (plus outer padding) after the first layout.
struct ButtonAreaMinWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Minimum below-preview height preference

/// Reports the natural (compressed) height of all content below the preview well.
/// MainWindowController observes this via AppState and uses it to set the window's
/// minimum height so the below-preview block is never clipped.
struct BelowPreviewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Button label helpers

/// Lays out a button label as [text ···· shortcut], matching the familiar
/// look of a pull-down menu item: label expands to fill available width,
/// shortcut string is right-aligned in muted type.
private func buttonRow(_ title: String, shortcut: String, showShortcut: Bool = true) -> some View {
    HStack(spacing: 4) {
        Text(title)
            .frame(maxWidth: .infinity, alignment: .leading)
        if showShortcut {
            Text(shortcut)
                .foregroundColor(.secondary)
                .font(.system(size: 11))
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView(appState: AppState())
        .frame(width: 480, height: 680)
}
