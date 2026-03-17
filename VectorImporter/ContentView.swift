import AppKit
import SwiftUI
import WebKit

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
        NSAttributedString(string: "Drag into Keynote", attributes: attrs)
            .draw(in: NSRect(x: 0, y: 15, width: 180, height: 30))
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
            withTitle: "Convert and Copy for Keynote",
            action: #selector(handleCopyForKeynote),
            keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = onCopyForKeynote != nil
        menu.addItem(NSMenuItem.separator())
        let clearItem = menu.addItem(
            withTitle: "Clear",
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
                    if let s = convertFileToSVGWithInkscape(url: url) {
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
                        let s = convertFileToSVGWithInkscape(url: tempURL)
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
        nsView.onDragStart = onDragStart
        nsView.onSVGDropped = onSVGDropped
        nsView.onCopyForKeynote = onCopyForKeynote
        nsView.onClear = onClear
    }
}

// MARK: - Responsive SVG renderer

/// A WKWebView-backed renderer that scales the SVG to fill its frame while
/// preserving aspect ratio.  Replaces the ZeeZide SVGWebView package, whose
/// minimal HTML wrapper lacks the CSS reset needed for height: 100% to work.
struct ResponsiveSVGWebView: NSViewRepresentable {

    let svg: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let prefs = WKPreferences()
        let config = WKWebViewConfiguration()
        config.preferences = prefs
        if #available(macOS 10.5, *) {
            let pagePrefs = WKWebpagePreferences()
            pagePrefs.preferredContentMode = .desktop
            if #available(macOS 11, *) {
                pagePrefs.allowsContentJavaScript = false
            }
            config.defaultWebpagePreferences = pagePrefs
        }
        config.allowsAirPlayForMediaPlayback = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

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
                MetadataRow(label: "Dimensions", value: "\(width) × \(height)")
            }
            MetadataRow(label: "Size", value: getFileSizeString(svgString: svgString))
            if let creator = extractSVGCreator(svgString: svgString) {
                MetadataRow(label: "Source", value: creator)
            }
        }
        .font(.system(size: 10, design: .monospaced))
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

    var statusMessage: String {
        switch appState.conversionStatus {
        case .converting:
            return "Converting via Inkscape…"
        case .failed:
            return "Conversion failed — no SVG or convertible data found."
        case .idle:
            break
        }
        if !localStatus.isEmpty { return localStatus }
        if !appState.svgString.isEmpty {
            return "Ready — drag the preview into Keynote, or Copy to Clipboard"
        }
        return "Open a file, paste from clipboard, or drop an SVG here"
    }

    var body: some View {
        VStack(spacing: 0) {

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
            .frame(minHeight: 100, maxHeight: .infinity)

            // ── Status ────────────────────────────────────────────────────
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
                        appState.conversionStatus == .failed ? .red : .secondary)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .frame(height: 50, alignment: .top)

            Divider().padding(.vertical, 8)

            // ── Action buttons ────────────────────────────────────────────
            let isConverting = appState.conversionStatus == .converting
            VStack(spacing: 8) {
                Button {
                    let picked = browseFile(into: appState)
                    // "(converting)" is the sentinel returned when a background
                    // conversion was kicked off — conversionStatus drives the
                    // message in that case, so we don't overwrite it here.
                    if picked != "(converting)" && !picked.isEmpty {
                        localStatus = "Loaded!"
                        appState.conversionStatus = .idle
                    }
                } label: {
                    Text("Open SVG File…").frame(maxWidth: .infinity)
                }
                .disabled(isConverting)

                Button {
                    let svg = convertClipboardToSVG()
                    if !svg.isEmpty {
                        appState.svgString = svg
                        appState.conversionStatus = .idle
                        if svgToClipboard(svgData: svg, appState: appState) != nil {
                            localStatus = "Ready to paste into Keynote!"
                        }
                    } else {
                        localStatus = "No SVG found on clipboard."
                    }
                } label: {
                    Text("Copy to Clipboard").frame(maxWidth: .infinity)
                }
                .disabled(appState.svgString.isEmpty || isConverting)
            }
            .padding(.horizontal)

            Spacer(minLength: 0)

            // ── Footer ────────────────────────────────────────────────────
            HStack {
                Text("VectorImporter")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        }
    }

    // MARK: Sub-views

    /// Shown when an SVG is loaded: renders the graphic and supports both
    /// outbound drag to Keynote and inbound replacement drops.
    private var loadedPreview: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)

            ResponsiveSVGWebView(svg: appState.svgString)

            // Single interaction layer — handles outbound drag, inbound drop,
            // and right-click menu with no Z-order conflict.
            SVGInteractionViewWrapper(
                onDragStart: { [weak appState] in
                    guard let svg = appState?.svgString else { return nil }
                    let url = makeTempSVGURL()
                    do {
                        try svg.write(to: url, atomically: true, encoding: .utf8)
                        appState?.bridgeFileURL = url
                    } catch {
                        NSLog("VectorImporter: error writing temp SVG: \(error)")
                        return nil
                    }
                    return url
                },
                onSVGDropped: { svg in
                    appState.svgString = svg
                    localStatus = "Loaded!"
                },
                onCopyForKeynote: {
                    if svgToClipboard(svgData: appState.svgString, appState: appState) != nil {
                        localStatus = "Copied to clipboard!"
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
                    localStatus = "Loaded!"
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

                Text("No SVG Loaded")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Text(
                    "Drop an SVG file here, open one with the button below,\n"
                        + "or copy artwork to your clipboard and click Copy to Clipboard"
                )
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - File browser helper

@discardableResult
func browseFile(into appState: AppState) -> String {
    let dialog = NSOpenPanel()
    dialog.title = "Choose a vector file"
    dialog.showsHiddenFiles = false
    dialog.canChooseDirectories = false
    dialog.allowsMultipleSelection = false

    // Always offer SVG. Offer PDF and AI only when Inkscape is available,
    // so the extra types don't appear greyed-out and confuse the user.
    var types = ["svg"]
    if inkscapeURL() != nil {
        types += ["pdf", "ai"]
    }
    dialog.allowedFileTypes = types

    guard dialog.runModal() == .OK, let url = dialog.url else { return "" }

    let ext = url.pathExtension.lowercased()

    if ext == "svg" {
        // Fast path — read directly.
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !content.isEmpty {
            appState.svgURL = url.path
            appState.svgString = content
        }
        return content
    }

    if ext == "pdf" || ext == "ai" {
        // Slow path — convert via Inkscape on a background thread.
        appState.conversionStatus = .converting
        DispatchQueue.global(qos: .userInitiated).async {
            let svg = convertFileToSVGWithInkscape(url: url)
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
        // Return a sentinel so the caller knows a conversion was kicked off,
        // without blocking the main thread.
        return "(converting)"
    }

    return ""
}

// MARK: - Preview

#Preview {
    ContentView(appState: AppState())
        .frame(width: 480, height: 680)
}
