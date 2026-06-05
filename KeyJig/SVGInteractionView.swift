import AppKit
import SwiftUI

// MARK: - Tooltip Text Constants

struct Tooltips {
    static let openFile = NSLocalizedString(
        "tooltip.open_file",
        comment: "Tooltip for the Open SVG File button")

    static let copyToClipboard = NSLocalizedString(
        "tooltip.copy_to_clipboard",
        comment: "Tooltip for the Copy to Clipboard button")

    static let placeInKeynote = NSLocalizedString(
        "tooltip.place_in_keynote",
        comment: "Tooltip for the Place in Keynote button")

    static let pullFromKeynote = NSLocalizedString(
        "tooltip.pull_from_keynote",
        comment: "Tooltip for the Convert Keynote Slide to PDF button")

    static let importSelectionFromKeynote = NSLocalizedString(
        "tooltip.import_selection_from_keynote",
        comment: "Tooltip for the Convert Keynote Clipboard to PDF button (Option-held variant)")

    static let savePDF = NSLocalizedString(
        "tooltip.save_pdf",
        comment: "Tooltip for the Save PDF button")

    static let copyPDF = NSLocalizedString(
        "tooltip.copy_pdf",
        comment: "Tooltip for the Copy PDF button")

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

    /// Called with one or more SVG strings when a valid inbound drop lands.
    /// Single drops fire immediately with a one-element array; multi-file drops
    /// fire once on the main thread after all files are processed serially.
    /// First element targets the receiving window; extras open new floating windows.
    var onSVGDropped: (([String]) -> Void)?

    /// Called synchronously on the main thread when a multi-file async drop
    /// begins. Use this to show a progress indicator while files are processed.
    var onMultiFileDropStarted: (() -> Void)?

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
    /// background queue. Calls `completion` on the main thread with all
    /// successfully converted results (failed files are silently skipped).
    static func processFilesSerially(_ urls: [URL], completion: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [String] = []
            for url in urls {
                let ext = url.pathExtension.lowercased()
                let type = ["svg", "pdf", "ai"].contains(ext) ? ext
                    : (sniffVectorFileType(at: url) ?? ext)
                switch type {
                case "svg":
                    if let s = try? String(contentsOf: url, encoding: .utf8),
                       s.contains("<svg") {
                        results.append(addSVGMargin(s))
                    }
                case "pdf", "ai":
                    if let s = convertToSVGWithInkscape(inputURL: url) {
                        results.append(s)
                    }
                default: break
                }
            }
            DispatchQueue.main.async { completion(results) }
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
            Self.processFilesSerially(fileURLs) { [weak self] svgs in
                guard !svgs.isEmpty else { return }
                self?.onSVGDropped?(svgs)
            }
            return true
        }

        // Single file or non-file-URL source (svg-image type, PDF pasteboard data,
        // SVG text): use the existing synchronous path.
        guard let svg = Self.svgString(from: sender.draggingPasteboard) else { return false }
        onSVGDropped?([svg])
        return true
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

    static func svgString(from pasteboard: NSPasteboard) -> String? {
        let svgType = NSPasteboard.PasteboardType("public.svg-image")
        if let data = pasteboard.data(forType: svgType),
            let s = String(data: data, encoding: .utf8),
            s.contains("<svg")
        { return addSVGMargin(s) }

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
                    if let s = try? String(contentsOf: url, encoding: .utf8), s.contains("<svg") {
                        return addSVGMargin(s)
                    }
                case "pdf", "ai":
                    if let s = convertToSVGWithInkscape(inputURL: url) { return s }
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
                        return s
                    }
                    try? FileManager.default.removeItem(at: tempURL)
                }
            }
        }

        if let s = pasteboard.string(forType: .string), s.contains("<svg") { return addSVGMargin(s) }
        return nil
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
    var onSVGDropped: (([String]) -> Void)?
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
        nsView.onCopyForKeynote = onCopyForKeynote
        nsView.onClear = onClear
    }
}
