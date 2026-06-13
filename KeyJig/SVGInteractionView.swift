import AppKit
import SwiftUI

// MARK: - Tooltip Text Constants

struct Tooltips {
    static let placeInKeynote = NSLocalizedString(
        "tooltip.place_in_keynote",
        comment: "Tooltip for the Place in Keynote button")

    static let pullFromKeynote = NSLocalizedString(
        "tooltip.pull_from_keynote",
        comment: "Tooltip for the Convert Keynote Slide to PDF button")

    static let importSelectionFromKeynote = NSLocalizedString(
        "tooltip.import_selection_from_keynote",
        comment: "Tooltip for the Convert Keynote Clipboard to PDF button (Option-held variant)")

    static let previewPDFLoaded = NSLocalizedString(
        "tooltip.preview_pdf_loaded",
        comment: "Tooltip for the preview area when a PDF is loaded")

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

// MARK: - Dropped content

/// One inbound vector from a drop: the (already ingested/converted) SVG plus
/// the file it came from, when the drop carried a file URL. The URL feeds
/// AppState.svgURL so the proxy icon and content-derived temp names can use
/// the original file name; pasteboard-data drops have no file and pass nil.
struct DroppedVector {
    let svg: String
    let sourceURL: URL?
}

/// Result of inspecting a single dropped item.
///   • `loaded`      — a usable vector; proceed.
///   • `rejected`    — recognised as SVG but refused (too large / unsafe / malformed);
///                     show the reason rather than ignoring the drop.
///   • `notHandled`  — nothing we can use on the pasteboard; let the drop fall through.
enum SVGDropOutcome {
    case loaded(DroppedVector)
    /// recognised as SVG but refused; `oversized` carries the raw content + byte
    /// count when the only reason is size (so the UI can offer a bypass).
    case rejected(String, oversized: (string: String, url: String?, bytes: Int)? = nil)
    case notHandled
}

// MARK: - Unified interaction view (drag source + drop target + context menu)

/// A single NSView that handles all three interaction modes without Z-order conflicts:
///   • mouseDown  → outbound drag to Keynote (drag source)
///   • draggingEntered/performDragOperation → inbound SVG drop (drag destination)
///   • menu(for:) → right-click context menu
class SVGInteractionView: NSView {

    // MARK: Callbacks

    /// Text shown on the drag image thumbnail. Defaults to "Drag into Keynote".
    var dragLabel: String = NSLocalizedString(
        "preview.drag_label",
        comment: "Text on the drag image thumbnail shown when dragging the SVG preview")

    /// Return the file URL to use as the drag payload, or nil to cancel the drag.
    var onDragStart: (() -> URL?)?

    /// Called with one or more dropped vectors when a valid inbound drop lands.
    /// Single drops fire immediately with a one-element array; multi-file drops
    /// fire once on the main thread after all files are processed serially.
    /// First element targets the receiving window; extras open new floating windows.
    var onSVGDropped: (([DroppedVector]) -> Void)?

    /// Called synchronously on the main thread when a multi-file async drop
    /// begins. Use this to show a progress indicator while files are processed.
    var onMultiFileDropStarted: (() -> Void)?

    /// Called on the main thread when a drop is refused (oversized, unsafe, or
    /// unreadable) and nothing was loaded. The argument is a user-facing reason.
    /// Lets the UI explain the refusal instead of silently ignoring the file.
    var onDropRejected: ((String) -> Void)?

    /// Called when a drop is rejected solely because the file exceeds the size limit.
    /// Passes the raw SVG string and optional source path so the UI can offer a bypass.
    var onOversizedSVGDropped: ((_ string: String, _ url: String?) -> Void)?

    /// Called when the user chooses "Convert and Copy for Keynote" from the context menu.
    var onCopyForKeynote: (() -> Void)?

    /// Called when the user chooses "Clear" from the context menu.
    var onClear: (() -> Void)? {
        didSet { trashButton?.isHidden = onClear == nil }
    }

    // MARK: Private state

    private var isDropHighlighted = false {
        didSet { needsDisplay = true }
    }

    private var trashButton: NSButton?

    // MARK: Multi-file helpers (also used by StatusBarDragProxy)

    /// Returns all valid vector file URLs from the pasteboard, up to `limit`.
    /// Filters by extension first, then falls back to content sniffing.
    static func validFileURLs(from pasteboard: NSPasteboard, limit: Int = 5) -> [URL] {
        (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
        .filter { url in
            let ext = url.pathExtension.lowercased()
            let type = ["svg", "pdf", "ai"].contains(ext) ? ext
                : (sniffVectorFileType(at: url) ?? ext)
            return ["svg", "pdf", "ai"].contains(type)
        }
        .prefix(limit)
        .map { $0 }
    }

    /// Converts a list of vector file URLs to SVG strings serially on a
    /// background queue. Calls `completion` on the main thread with the
    /// successfully converted results and a user-facing reason for each file
    /// that was refused, so callers can explain an all-failed drop.
    static func processFilesSerially(
        _ urls: [URL],
        completion: @escaping (_ results: [DroppedVector], _ rejections: [String]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [DroppedVector] = []
            var rejections: [String] = []
            for url in urls {
                let ext = url.pathExtension.lowercased()
                let type = ["svg", "pdf", "ai"].contains(ext) ? ext
                    : (sniffVectorFileType(at: url) ?? ext)
                switch type {
                case "svg":
                    guard let s = try? String(contentsOf: url, encoding: .utf8) else {
                        rejections.append(SVGIngestError.notSVG.userMessage)
                        continue
                    }
                    switch checkedIngestSVG(s) {
                    case .success(let safe):
                        results.append(DroppedVector(svg: safe, sourceURL: url))
                    case .failure(let err):
                        rejections.append(err.userMessage)
                    }
                case "pdf", "ai":
                    if let s = convertToSVGWithInkscape(inputURL: url) {
                        results.append(DroppedVector(svg: s, sourceURL: url))
                    } else {
                        rejections.append(NSLocalizedString(
                            "error.convert.failed",
                            comment: "Error when Inkscape conversion of a dropped PDF/AI fails"))
                    }
                default:
                    rejections.append(SVGIngestError.notSVG.userMessage)
                }
            }
            DispatchQueue.main.async { completion(results, rejections) }
        }
    }

    // Accepted inbound pasteboard types — also used by StatusBarDragProxy.
    static let acceptedTypes: [NSPasteboard.PasteboardType] = [
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
        setupTrashButton()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(Self.acceptedTypes)
        setupTrashButton()
    }

    private func setupTrashButton() {
        let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        let base = NSImage(
            systemSymbolName: "trash.circle.fill",
            accessibilityDescription: NSLocalizedString(
                "context_menu.clear",
                comment: "Context menu: clear the loaded SVG"))
        guard let image = base?.withSymbolConfiguration(config) else { return }
        let btn = NSButton(image: image, target: self, action: #selector(handleClear))
        btn.bezelStyle = .smallSquare
        btn.isBordered = false
        btn.imageScaling = .scaleNone
        btn.contentTintColor = .secondaryLabelColor
        btn.isHidden = true
        addSubview(btn)
        trashButton = btn
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let size: CGFloat = 32
        let padding: CGFloat = 8
        trashButton?.frame = NSRect(
            x: bounds.maxX - size - padding,
            y: padding,
            width: size, height: size)
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let fileURL = onDragStart?() else {
            super.mouseDown(with: event)
            return
        }

        let dragPoint = event.locationInWindow
        let viewPoint = self.convert(dragPoint, from: nil)

        let dragImage = NSImage(size: NSSize(width: 180, height: 180))
        dragImage.lockFocus()
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: 180, height: 180),
            xRadius: 12, yRadius: 12
        ).fill()
        if let icon = NSImage(
            systemSymbolName: "photo.fill.on.rectangle.fill",
            accessibilityDescription: "image"
        ) {
            icon.draw(in: NSRect(x: 50, y: 60, width: 80, height: 80))
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]
        NSAttributedString(string: dragLabel, attributes: attrs)
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
        guard sender.draggingSource as? SVGInteractionView !== self else { return [] }
        guard Self.canHandleDropData(sender.draggingPasteboard) else { return [] }
        isDropHighlighted = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource as? SVGInteractionView !== self else { return [] }
        guard Self.canHandleDropData(sender.draggingPasteboard) else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropHighlighted = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard sender.draggingSource as? SVGInteractionView !== self else { return false }
        return Self.canHandleDropData(sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropHighlighted = false
        guard sender.draggingSource as? SVGInteractionView !== self else { return false }
        guard Self.canHandleDropData(sender.draggingPasteboard) else { return false }

        // Multi-file: process serially on a background queue, then fire the
        // callback once with all results. Return true immediately so the drop
        // animation completes without waiting for Inkscape conversions.
        let fileURLs = Self.validFileURLs(from: sender.draggingPasteboard)
        if fileURLs.count > 1 {
            onMultiFileDropStarted?()
            Self.processFilesSerially(fileURLs) { [weak self] svgs, rejections in
                if svgs.isEmpty {
                    // Nothing loaded — explain why and clear any progress state.
                    self?.onDropRejected?(rejections.first ?? SVGIngestError.notSVG.userMessage)
                } else {
                    self?.onSVGDropped?(svgs)
                }
            }
            return true
        }

        // Single file or non-file-URL source (svg-image type, PDF pasteboard data,
        // SVG text): use the existing synchronous path.
        switch Self.dropOutcome(from: sender.draggingPasteboard) {
        case .loaded(let dropped):
            onSVGDropped?([dropped])
            return true
        case .rejected(let reason, let oversized):
            if let o = oversized {
                onOversizedSVGDropped?(o.string, o.url)
            }
            onDropRejected?(reason)
            return true
        case .notHandled:
            return false
        }
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        isDropHighlighted = false
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard onCopyForKeynote != nil || onClear != nil else { return nil }
        let menu = NSMenu()
        if onCopyForKeynote != nil {
            let copyItem = menu.addItem(
                withTitle: NSLocalizedString(
                    "context_menu.copy_for_keynote",
                    comment: "Context menu: convert and copy SVG to clipboard for Keynote"),
                action: #selector(handleCopyForKeynote),
                keyEquivalent: "")
            copyItem.target = self
            menu.addItem(NSMenuItem.separator())
        }
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

    // MARK: SVG pasteboard helpers
    // Both are static so StatusBarDragProxy can call them without an instance.

    /// Inspects a single inbound drop and reports a usable vector, a refusal with
    /// a reason, or "nothing we handle." When a source is recognised as SVG but
    /// fails the size/safety screen, the reason is returned so the drop is
    /// explained rather than silently ignored.
    static func dropOutcome(from pasteboard: NSPasteboard) -> SVGDropOutcome {
        let convertFailed = NSLocalizedString(
            "error.convert.failed",
            comment: "Error when Inkscape conversion of a dropped PDF/AI fails")

        let svgType = NSPasteboard.PasteboardType("public.svg-image")
        if let data = pasteboard.data(forType: svgType),
            let s = String(data: data, encoding: .utf8) {
            switch checkedIngestSVG(s) {
            case .success(let safe): return .loaded(DroppedVector(svg: safe, sourceURL: nil))
            case .failure(let err):
                if case .tooLarge(let bytes) = err {
                    return .rejected(err.userMessage, oversized: (string: s, url: nil, bytes: bytes))
                }
                return .rejected(err.userMessage)
            }
        }

        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]
        {
            for url in urls {
                let ext = url.pathExtension.lowercased()
                let type = ["svg", "pdf", "ai"].contains(ext) ? ext
                    : (sniffVectorFileType(at: url) ?? ext)
                switch type {
                case "svg":
                    guard let s = try? String(contentsOf: url, encoding: .utf8) else {
                        return .rejected(SVGIngestError.notSVG.userMessage)
                    }
                    switch checkedIngestSVG(s) {
                    case .success(let safe): return .loaded(DroppedVector(svg: safe, sourceURL: url))
                    case .failure(let err):
                        if case .tooLarge(let bytes) = err {
                            return .rejected(err.userMessage, oversized: (string: s, url: url.path, bytes: bytes))
                        }
                        return .rejected(err.userMessage)
                    }
                case "pdf", "ai":
                    if let s = convertToSVGWithInkscape(inputURL: url) {
                        return .loaded(DroppedVector(svg: s, sourceURL: url))
                    }
                    return .rejected(convertFailed)
                default:
                    break
                }
            }
        }

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
                        return .loaded(DroppedVector(svg: s, sourceURL: nil))
                    }
                    try? FileManager.default.removeItem(at: tempURL)
                    return .rejected(convertFailed)
                }
            }
        }

        if let s = pasteboard.string(forType: .string) {
            switch checkedIngestSVG(s) {
            case .success(let safe): return .loaded(DroppedVector(svg: safe, sourceURL: nil))
            case .failure(.notSVG): break  // arbitrary text on the pasteboard, not a refusal
            case .failure(let err):
                if case .tooLarge(let bytes) = err {
                    return .rejected(err.userMessage, oversized: (string: s, url: nil, bytes: bytes))
                }
                return .rejected(err.userMessage)
            }
        }
        return .notHandled
    }

    static func canHandleDropData(_ pasteboard: NSPasteboard) -> Bool {
        let svgType = NSPasteboard.PasteboardType("public.svg-image")
        if let data = pasteboard.data(forType: svgType),
            let s = String(data: data, encoding: .utf8), s.contains("<svg")
        { return true }

        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]
        {
            for url in urls {
                let ext = url.pathExtension.lowercased()
                let type = ["svg", "pdf", "ai"].contains(ext) ? ext
                    : (sniffVectorFileType(at: url) ?? ext)
                switch type {
                case "svg":
                    if let s = try? String(contentsOf: url, encoding: .utf8),
                        s.contains("<svg") { return true }
                case "pdf", "ai":
                    return true
                default:
                    break
                }
            }
        }

        if inkscapeURL() != nil {
            let pdfTypes: [NSPasteboard.PasteboardType] = [
                NSPasteboard.PasteboardType("com.adobe.pdf"),
                NSPasteboard.PasteboardType("Apple PDF pasteboard type"),
            ]
            for type in pdfTypes {
                if let data = pasteboard.data(forType: type), !data.isEmpty { return true }
            }
        }

        if let s = pasteboard.string(forType: .string), s.contains("<svg") { return true }
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

    var onDragStart: (() -> URL?)?
    var onMultiFileDropStarted: (() -> Void)?
    var onSVGDropped: (([DroppedVector]) -> Void)?
    var onDropRejected: ((String) -> Void)?
    var onOversizedSVGDropped: ((_ string: String, _ url: String?) -> Void)?
    var onCopyForKeynote: (() -> Void)?
    var onClear: (() -> Void)?
    var dragLabel: String = NSLocalizedString(
        "preview.drag_label",
        comment: "Text on the drag image thumbnail shown when dragging the SVG preview")

    func makeNSView(context: Context) -> SVGInteractionView { SVGInteractionView() }

    func updateNSView(_ nsView: SVGInteractionView, context: Context) {
        nsView.toolTip = Tooltips.previewAreaLoaded
        nsView.dragLabel = dragLabel
        nsView.onDragStart = onDragStart
        nsView.onSVGDropped = onSVGDropped
        nsView.onMultiFileDropStarted = onMultiFileDropStarted
        nsView.onDropRejected = onDropRejected
        nsView.onOversizedSVGDropped = onOversizedSVGDropped
        nsView.onCopyForKeynote = onCopyForKeynote
        nsView.onClear = onClear
    }
}
