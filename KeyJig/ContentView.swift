import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import os

private let log = Logger(subsystem: "com.cyzor.KeyJig", category: "ContentView")

// MARK: - Tooltip Text Constants

struct Tooltips {
    static let openFile = NSLocalizedString(
        "tooltip.open_file",
        comment: "Tooltip for the Open SVG File button")

    static let copyToClipboard = NSLocalizedString(
        "tooltip.copy_to_clipboard",
        comment: "Tooltip for the Copy to Clipboard button")

    static let readyStatus = NSLocalizedString(
        "tooltip.status_ready",
        comment: "Tooltip shown on the status area when an SVG is ready")

    static let previewAreaLoaded = NSLocalizedString(
        "tooltip.preview_loaded",
        comment: "Tooltip for the SVG preview area when an SVG is loaded")

    static let previewAreaEmpty = NSLocalizedString(
        "tooltip.preview_empty",
        comment: "Tooltip for the SVG preview drop well when empty")
}

// MARK: - Unified interaction view (drag source + drop target + context menu)

/// A single NSView that handles all three interaction modes without Z-order conflicts:
///   • mouseDown  → outbound drag to Keynote (drag source)
///   • draggingEntered/performDragOperation → inbound SVG drop (drag destination)
///   • menu(for:) → right-click context menu
class SVGInteractionView: NSView {

    // MARK: Callbacks

    /// Return the file URL to use as the drag payload, or nil to cancel the drag.
    var onDragStart: (() -> URL?)?

    /// Called with the loaded SVG string when a valid inbound drop lands.
    var onSVGDropped: ((String) -> Void)?

    /// Called when the user chooses "Convert and Copy for Keynote" from the context menu.
    var onCopyForKeynote: (() -> Void)?

    /// Called when the user chooses "Clear" from the context menu.
    var onClear: (() -> Void)?

    // MARK: Private state

    private var isDropHighlighted = false {
        didSet { needsDisplay = true }
    }

    // Accepted inbound pasteboard types
    private static let acceptedTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        NSPasteboard.PasteboardType("public.svg-image"),
        NSPasteboard.PasteboardType("public.file-url"),
        NSPasteboard.PasteboardType("com.adobe.pdf"),
        NSPasteboard.PasteboardType("Apple PDF pasteboard type"),
        .string,
    ]

    // MARK: Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isDropHighlighted else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: 8, yRadius: 8)
        path.lineWidth = 2
        path.stroke()
    }

    // MARK: Outbound drag (NSDraggingSource)

    override func mouseDown(with event: NSEvent) {
        // If there is no drag payload, fall through to default behaviour
        // (which lets SwiftUI handle taps etc.).
        guard let fileURL = onDragStart?() else {
            super.mouseDown(with: event)
            return
        }

        let dragPoint = event.locationInWindow
        let viewPoint = self.convert(dragPoint, from: nil)

        // Build a lightweight drag image
        let dragImage = NSImage(size: NSSize(width: 180, height: 180))
        dragImage.lockFocus()
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: 180, height: 180),
            xRadius: 12, yRadius: 12
        ).fill()
        if #available(macOS 11.0, *) {
            if let icon = NSImage(
                systemSymbolName: "photo.fill.on.rectangle.fill",
                accessibilityDescription: "image"
            ) {
                icon.draw(in: NSRect(x: 50, y: 60, width: 80, height: 80))
            }
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]
        NSAttributedString(
            string: NSLocalizedString(
                "preview.drag_label",
                comment: "Text on the drag image thumbnail shown when dragging the SVG preview"),
            attributes: attrs
        ).draw(in: NSRect(x: 0, y: 15, width: 180, height: 30))
        dragImage.unlockFocus()

        let draggingItem = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        draggingItem.setDraggingFrame(
            NSRect(x: viewPoint.x - 90, y: viewPoint.y - 90, width: 180, height: 180),
            contents: dragImage)
        _ = self.beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    // MARK: Inbound drop (NSDraggingDestination)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Reject drags that originated from this same view (outbound drags
        // loop back through the destination protocol; we don't want to accept
        // our own payload as a new drop).
        guard sender.draggingSource as? SVGInteractionView !== self else { return [] }
        guard canHandleDropData(sender.draggingPasteboard) else { return [] }
        isDropHighlighted = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource as? SVGInteractionView !== self else { return [] }
        guard canHandleDropData(sender.draggingPasteboard) else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropHighlighted = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard sender.draggingSource as? SVGInteractionView !== self else { return false }
        return canHandleDropData(sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropHighlighted = false
        guard sender.draggingSource as? SVGInteractionView !== self else { return false }
        guard let svg = svgString(from: sender.draggingPasteboard) else { return false }
        onSVGDropped?(svg)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        isDropHighlighted = false
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        // Only show a menu when there is loaded content to act on.
        guard onCopyForKeynote != nil || onClear != nil else { return nil }
        let menu = NSMenu()
        let copyItem = menu.addItem(
            withTitle: NSLocalizedString(
                "context_menu.copy_for_keynote",
                comment: "Context menu: convert and copy SVG to clipboard for Keynote"),
            action: #selector(handleCopyForKeynote),
            keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = onCopyForKeynote != nil
        menu.addItem(NSMenuItem.separator())
        let clearItem = menu.addItem(
            withTitle: NSLocalizedString(
                "context_menu.clear",
                comment: "Context menu: clear the loaded SVG"),
            action: #selector(handleClear),
            keyEquivalent: "")
        clearItem.target = self
        clearItem.isEnabled = onClear != nil
        return menu
    }

    @objc private func handleCopyForKeynote() { onCopyForKeynote?() }
    @objc private func handleClear() { onClear?() }

    // MARK: SVG pasteboard helper

    /// Tries every accepted type in priority order and returns the first valid SVG string.
    private func svgString(from pasteboard: NSPasteboard) -> String? {
        // 1. Explicit SVG data type (Affinity Designer, some exporters)
        let svgType = NSPasteboard.PasteboardType("public.svg-image")
        if let data = pasteboard.data(forType: svgType),
            let s = String(data: data, encoding: .utf8),
            s.contains("<svg")
        {
            return s
        }

        // 2. File URL — SVG files are read directly; PDF and AI files are
        //    converted via Inkscape if it is installed.
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]
        {
            for url in urls {
                switch url.pathExtension.lowercased() {
                case "svg":
                    if let s = try? String(contentsOf: url, encoding: .utf8),
                        s.contains("<svg")
                    {
                        return s
                    }
                case "pdf", "ai":
                    // Synchronous — drop operations are already dispatched off
                    // the main thread by AppKit's drag machinery.
                    if let s = convertToSVGWithInkscape(inputURL: url) {
                        return s
                    }
                default:
                    break
                }
            }
        }

        // 3. PDF data on the pasteboard itself (e.g. dragged from a browser or
        //    another app that provides PDF but not a file URL).
        //    Only attempt if Inkscape is available.
        if inkscapeURL() != nil {
            let pdfTypes: [NSPasteboard.PasteboardType] = [
                NSPasteboard.PasteboardType("com.adobe.pdf"),
                NSPasteboard.PasteboardType("Apple PDF pasteboard type"),
            ]
            for type in pdfTypes {
                if let data = pasteboard.data(forType: type), !data.isEmpty {
                    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("pdf")
                    if (try? data.write(to: tempURL)) != nil,
                        let s = convertToSVGWithInkscape(inputURL: tempURL)
                    {
                        try? FileManager.default.removeItem(at: tempURL)
                        return s
                    }
                    try? FileManager.default.removeItem(at: tempURL)
                }
            }
        }

        // 4. Plain string containing SVG markup
        if let s = pasteboard.string(forType: .string), s.contains("<svg") {
            return s
        }

        return nil
    }

    /// Fast check: can we handle this drag without actually converting?
    /// Returns true if the pasteboard contains acceptable content (SVG, file URLs, etc.)
    /// WITHOUT triggering expensive Inkscape conversions for PDF/AI files.
    private func canHandleDropData(_ pasteboard: NSPasteboard) -> Bool {
        // 1. Explicit SVG data type
        let svgType = NSPasteboard.PasteboardType("public.svg-image")
        if let data = pasteboard.data(forType: svgType),
            let s = String(data: data, encoding: .utf8),
            s.contains("<svg")
        {
            return true
        }

        // 2. File URLs — check type without converting
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]
        {
            for url in urls {
                switch url.pathExtension.lowercased() {
                case "svg", "pdf", "ai":
                    // For SVG, we can verify content; for PDF/AI, just trust the extension
                    if url.pathExtension.lowercased() == "svg" {
                        if let s = try? String(contentsOf: url, encoding: .utf8),
                            s.contains("<svg")
                        {
                            return true
                        }
                    } else {
                        // PDF/AI files are convertible, return true without actually converting
                        return true
                    }
                default:
                    break
                }
            }
        }

        // 3. PDF data on pasteboard (need Inkscape to handle)
        if inkscapeURL() != nil {
            let pdfTypes: [NSPasteboard.PasteboardType] = [
                NSPasteboard.PasteboardType("com.adobe.pdf"),
                NSPasteboard.PasteboardType("Apple PDF pasteboard type"),
            ]
            for type in pdfTypes {
                if let data = pasteboard.data(forType: type), !data.isEmpty {
                    return true  // We can handle it (Inkscape is available)
                }
            }
        }

        // 4. Plain SVG string
        if let s = pasteboard.string(forType: .string), s.contains("<svg") {
            return true
        }

        return false
    }
}

// Make SVGInteractionView a proper drag source
extension SVGInteractionView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .copy }
}

// MARK: - SwiftUI wrapper

struct SVGInteractionViewWrapper: NSViewRepresentable {

    // Drag-source callback
    var onDragStart: (() -> URL?)?

    // Drop-destination callback
    var onSVGDropped: ((String) -> Void)?

    // Context-menu callbacks (nil when the well is empty)
    var onCopyForKeynote: (() -> Void)?
    var onClear: (() -> Void)?

    func makeNSView(context: Context) -> SVGInteractionView {
        SVGInteractionView()
    }

    func updateNSView(_ nsView: SVGInteractionView, context: Context) {
        nsView.toolTip = Tooltips.previewAreaLoaded
        nsView.onDragStart = onDragStart
        nsView.onSVGDropped = onSVGDropped
        nsView.onCopyForKeynote = onCopyForKeynote
        nsView.onClear = onClear
    }
}

// MARK: - Responsive SVG renderer

/// A WKWebView-backed renderer that scales the SVG to fill its frame while
/// preserving aspect ratio. The HTML wrapper in `wrapSVGForResponsiveDisplay`
/// (see `SVGProcessing.swift`) supplies the CSS reset and `position: fixed`
/// trick that makes `height: 100%` actually fill the viewport.
struct ResponsiveSVGWebView: NSViewRepresentable {

    let svg: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let prefs = WKPreferences()
        let config = WKWebViewConfiguration()
        config.preferences = prefs
        if #available(macOS 10.15, *) {
            let pagePrefs = WKWebpagePreferences()
            pagePrefs.preferredContentMode = .desktop
            if #available(macOS 11, *) {
                pagePrefs.allowsContentJavaScript = false
            }
            config.defaultWebpagePreferences = pagePrefs
        }
        config.allowsAirPlayForMediaPlayback = false

        let webView = WKWebView(frame: .zero, configuration: config)
        // Prevent WebKit's native layer from painting a white background behind
        // the transparent HTML. Private KVC — guarded so a future removal
        // degrades to a white preview rather than a crash.
        if webView.responds(to: Selector(("setDrawsBackground:"))) {
            webView.setValue(false, forKey: "drawsBackground")
        }

        let html = wrapSVGForResponsiveDisplay(svgString: svg)
        context.coordinator.lastSVG = svg
        webView.loadHTMLString(html, baseURL: nil)
        resetViewport(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
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

    class Coordinator {
        var lastSVG: String = ""
    }
}

// MARK: - Metadata overlay

struct MetadataOverlay: View {
    let svgString: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let (width, height) = extractSVGDimensions(svgString: svgString) {
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
                value: getFileSizeString(svgString: svgString))
            if let creator = extractSVGCreator(svgString: svgString) {
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

// MARK: - Main content view

struct ContentView: View {
    @ObservedObject var appState: AppState
    @State private var localStatus: String = ""

    init(appState: AppState = AppState()) {
        self.appState = appState
    }

    /// Returns the app's build date derived from the executable's link-time
    /// modification timestamp — updates automatically on every build.
    private static let buildDate: String = {
        let fallback = "Unknown"
        guard let url = Bundle.main.executableURL,
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let date = attrs[.modificationDate] as? Date
        else { return fallback }
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .none
        return fmt.string(from: date)
    }()

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
        if let (w, h) = extractSVGDimensions(svgString: appState.svgString) {
            dims = "\(Int(w.rounded())) × \(Int(h.rounded()))"
        } else {
            dims = "—"
        }
        let size = getFileSizeString(svgString: appState.svgString)
        return String.localizedStringWithFormat(format, dims, size)
    }

    var statusMessage: String {
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
        let hasContent = !appState.svgString.isEmpty
        let base: String
        if !localStatus.isEmpty {
            base = localStatus
        } else if hasContent {
            base = NSLocalizedString(
                "status.ready",
                comment: "Status: SVG is loaded and ready to use")
        } else {
            return ""
        }
        return hasContent ? base + "\n\n" + Self.breakApartInstruction : base
    }

    var body: some View {
        VStack(spacing: 4) {

            // ── Preview / drop well ───────────────────────────────────────
            Group {
                if !appState.svgString.isEmpty {
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

            // ── Status ────────────────────────────────────────────────────
            if !statusMessage.isEmpty {
                HStack(spacing: 6) {
                    if appState.conversionStatus == .converting {
                        if #available(macOS 11.0, *) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        } else {
                            // Fallback: animated ellipsis is handled in statusMessage
                            EmptyView()
                        }
                    }
                    Text(statusMessage)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundColor(
                            appState.conversionStatus == .failed ? .red : .secondary
                        )
                        .accessibilityLabel(statusMessage)
                        .accessibilityAddTraits(.updatesFrequently)
                        .accessibilityIdentifier("status_message")
                        .onChange(of: statusMessage) { newValue in
                            announceToVoiceOver(newValue)
                        }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .frame(minHeight: 50, alignment: .top)
                .help(appState.svgString.isEmpty ? "" : Tooltips.readyStatus)
            }

            Divider().padding(.vertical, 8)

            // ── Action buttons ────────────────────────────────────────────
            let isConverting = appState.conversionStatus == .converting
            VStack(spacing: 8) {
                Button {
                    // For .converting, conversionStatus drives the message
                    // until the background work finishes — don't overwrite it.
                    if case .loaded = browseFile(into: appState) {
                        localStatus = ""
                        appState.conversionStatus = .idle
                    }
                } label: {
                    Text(
                        NSLocalizedString(
                            "button.open_svg_file",
                            comment: "Button: opens the file picker to load an SVG")
                    )
                    .frame(maxWidth: .infinity)
                }
                .help(Tooltips.openFile)
                .keyboardShortcut("o", modifiers: [.command])
                .disabled(isConverting)

                Button {
                    let svg = convertClipboardToSVG()
                    if !svg.isEmpty {
                        appState.svgString = svg
                        appState.conversionStatus = .idle
                        if svgToClipboard(svgData: svg, appState: appState) != nil {
                            localStatus = ""
                        }
                    } else {
                        localStatus = NSLocalizedString(
                            "status.no_svg_on_clipboard",
                            comment: "Error message when no SVG is found on the clipboard")
                    }
                } label: {
                    Text(
                        NSLocalizedString(
                            "button.copy_to_clipboard",
                            comment:
                                "Button: copies the loaded SVG to the clipboard in Keynote format")
                    )
                    .frame(maxWidth: .infinity)
                }
                .help(Tooltips.copyToClipboard)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(appState.svgString.isEmpty || isConverting)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider()

            // ── Footer ────────────────────────────────────────────────────
            Text(
                String(
                    format: NSLocalizedString(
                        "footer.build_date",
                        comment: "Footer label showing the app build date; %@ is the date string"),
                    Self.buildDate)
            )
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding()
        }
    }

    // MARK: Sub-views

    /// Shown when an SVG is loaded: renders the graphic and supports both
    /// outbound drag to Keynote and inbound replacement drops.
    private var loadedPreview: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)

            ResponsiveSVGWebView(svg: appState.svgString)
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
                onSVGDropped: { svg in
                    appState.svgString = svg
                    localStatus = ""
                },
                onCopyForKeynote: {
                    if svgToClipboard(svgData: appState.svgString, appState: appState) != nil {
                        localStatus = NSLocalizedString(
                            "status.copied",
                            comment:
                                "Confirmation shown after copying to clipboard via context menu")
                    }
                },
                onClear: {
                    appState.svgString = ""
                    appState.svgURL = ""
                    appState.bridgeFileURL = nil
                    appState.conversionStatus = .idle
                    localStatus = ""
                }
            )

            // Metadata badge — no hit testing so events reach the layer below.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    MetadataOverlay(svgString: appState.svgString)
                        .padding(8)
                }
            }
            .allowsHitTesting(false)
        }
        .help(Tooltips.previewAreaLoaded)
        .onReceive(appState.$svgString) { newValue in
            // When content arrives externally (clipboard detection, drop),
            // clear any stale local status so the computed statusMessage shows.
            if !newValue.isEmpty {
                localStatus = ""
            }
        }
    }

    /// Shown when no SVG is loaded: drop target only, no drag source or menu.
    private var emptyWell: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)

            // Interaction layer (drop only — onDragStart and menu callbacks are nil).
            SVGInteractionViewWrapper(
                onSVGDropped: { svg in
                    appState.svgString = svg
                    localStatus = ""
                }
            )

            // Visual prompt — no hit testing so drops reach the layer below.
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

// MARK: - File browser helper

/// Result of presenting the open-file dialog.
/// `.loaded` means an SVG was read synchronously and `appState.svgString` is now populated.
/// `.converting` means a PDF/AI was picked and Inkscape conversion is running on a
///     background queue — `appState.conversionStatus` will transition to `.idle`/`.failed`.
/// `.cancelled` means the user dismissed the dialog or the file failed to read.
enum BrowseResult {
    case loaded
    case converting
    case cancelled
}

@discardableResult
func browseFile(into appState: AppState) -> BrowseResult {
    let dialog = NSOpenPanel()
    dialog.title = NSLocalizedString(
        "file_dialog.title",
        comment: "Title of the file open panel")
    dialog.showsHiddenFiles = false
    dialog.canChooseDirectories = false
    dialog.allowsMultipleSelection = false

    // Always offer SVG. Offer PDF and AI only when Inkscape is available,
    // so the extra types don't appear greyed-out and confuse the user.
    var types: [UTType] = [.svg]
    if inkscapeURL() != nil {
        types.append(.pdf)
        if let aiType = UTType(filenameExtension: "ai") {
            types.append(aiType)
        }
    }
    dialog.allowedContentTypes = types

    guard dialog.runModal() == .OK, let url = dialog.url else { return .cancelled }

    let ext = url.pathExtension.lowercased()

    if ext == "svg" {
        // Fast path — read directly.
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard !content.isEmpty else { return .cancelled }
        appState.svgURL = url.path
        appState.svgString = content
        return .loaded
    }

    if ext == "pdf" || ext == "ai" {
        // Slow path — convert via Inkscape on a background thread.
        appState.conversionStatus = .converting
        DispatchQueue.global(qos: .userInitiated).async {
            let svg = convertToSVGWithInkscape(inputURL: url)
            DispatchQueue.main.async {
                if let svg = svg, !svg.isEmpty {
                    appState.svgURL = url.path
                    appState.svgString = svg
                    appState.conversionStatus = .idle
                } else {
                    appState.conversionStatus = .failed
                }
            }
        }
        return .converting
    }

    return .cancelled
}

// MARK: - Preview

#Preview {
    ContentView(appState: AppState())
        .frame(width: 480, height: 680)
}
