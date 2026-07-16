import Foundation
import PDFKit

// MARK: - SVG Size Limit

/// Upper bound on SVG payload size we will write to the pasteboard or to a
/// temp file. Keynote's importer struggles with multi-megabyte SVGs, and
/// passing very large strings through `String.write(to:)` and the pasteboard
/// risks blocking the UI. 50 MB is generous in practice; legitimate vector
/// art is almost always under 1 MB.
/// (Defined here rather than in ClipboardHelpers so the ingest gate and its
/// tests don't depend on the clipboard layer.)
let maxSVGBytes = 50 * 1024 * 1024

// MARK: - File-type detection by content

/// Identifies a vector file's format by examining content rather than extension.
/// Reads at most 4 KB — enough for unambiguous magic bytes and a typical SVG preamble.
/// Returns "svg", "pdf", or "ai"; nil when the content is unrecognised.
///
/// Signatures checked:
///   %PDF-   (offset 0, 5 bytes) → PDF, including AI files saved in PDF format
///   %!PS    (offset 0, 4 bytes) → EPS / legacy AI (PostScript)
///   <svg    (anywhere in first 4 KB of UTF-8 text) → SVG
func sniffVectorFileType(at url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let header = handle.readData(ofLength: 4096)
    guard !header.isEmpty else { return nil }

    // PDF — covers native PDF and AI saved as PDF
    if header.count >= 5,
       header[0] == 0x25, header[1] == 0x50, header[2] == 0x44,
       header[3] == 0x46, header[4] == 0x2D { return "pdf" }

    // EPS / legacy AI (PostScript)
    if header.count >= 4,
       header[0] == 0x25, header[1] == 0x21,
       header[2] == 0x50, header[3] == 0x53 { return "ai" }

    // SVG — XML text, look for the root element tag
    if let text = String(data: header, encoding: .utf8), text.contains("<svg") { return "svg" }
    if let text = String(data: header, encoding: .utf16), text.contains("<svg") { return "svg" }

    return nil
}

/// True when the PDF is an AI placeholder page (saved without "Create PDF Compatible File").
/// "Adobe® Illustrator" (brand name with ®) appears in the placeholder in every locale.
func aiPDFLayerIsPlaceholder(at url: URL) -> Bool {
    guard let doc = PDFDocument(url: url),
          let page = doc.page(at: 0),
          let text = page.string else { return false }
    return text.contains("Adobe\u{00AE} Illustrator")
}

// MARK: - SVG Validation

/// Errors that can occur during SVG validation.
enum SVGValidationError: Error, LocalizedError {
    case empty
    case notSVGElement
    case containsDangerousContent

    var errorDescription: String? {
        switch self {
        case .empty:
            return "SVG content is empty"
        case .notSVGElement:
            return "Content does not contain an <svg> element"
        case .containsDangerousContent:
            return
                "SVG contains potentially dangerous content (scripts, event handlers, or external references)"
        }
    }
}

/// Validates that the given string is safe, well-formed XML containing an
/// <svg> root element. Returns nil if valid; returns an error otherwise.
func validateSVG(_ string: String) -> SVGValidationError? {
    guard !string.isEmpty else { return .empty }
    guard string.contains("<svg") else { return .notSVGElement }
    // Defence-in-depth screen for the most common XSS vectors carried by
    // SVGs scraped from the web. The WebKit preview already runs with
    // JavaScript disabled (see ResponsiveSVGWebView.makeNSView), so this is
    // belt-and-braces — but it also keeps us from copying anything obviously
    // hostile onto the system pasteboard. Not a substitute for a real XML
    // sanitiser; if a new attack surface comes up, extend this list.
    let dangerousPatterns = ["<script", "javascript:", "<foreignObject"]
    for pattern in dangerousPatterns {
        if string.range(of: pattern, options: .caseInsensitive) != nil {
            return .containsDangerousContent
        }
    }
    // Catch any on* event handler attribute (onerror=, onclick=, onload=, onbegin=, etc.)
    if string.range(of: #"\bon\w+\s*="#, options: [.regularExpression, .caseInsensitive]) != nil {
        return .containsDangerousContent
    }
    // External references: any href (SVG 2) or xlink:href (SVG 1.1) pointing
    // at a remote URL. Matched as a regex — namespace *declarations*
    // (xmlns:xlink="http://…") don't contain "href=" and pass untouched.
    if string.range(
        of: #"(?:xlink:)?href\s*=\s*["']\s*(?:https?|ftp)://"#,
        options: [.regularExpression, .caseInsensitive]) != nil
    {
        return .containsDangerousContent
    }
    return nil
}

// MARK: - SVG Ingest Gate

/// Single entry point for SVG text arriving from outside the app (clipboard,
/// drag-and-drop, file open). Enforces the size cap and the dangerous-content
/// screen, then applies the standard edge margin. Returns nil when rejected.
func ingestSVG(_ string: String) -> String? {
    try? checkedIngestSVG(string).get()
}

/// Reads an SVG file from disk, accepting either UTF-8 or UTF-16 (BOM-carrying).
/// UTF-16 SVGs exist in the wild — the clipboard ingest path already accepts
/// both, and the file-URL paths (drop, File → Open, `load SVG file`,
/// session-restore) all need the same treatment or a UTF-16 file is rejected
/// at the decode step. Throws on read error so callers can distinguish
/// "unreadable" from "not an SVG" (which is the encoding-failure case, returned
/// as nil by the caller via `try?`).
func readSVGFile(at url: URL) throws -> String? {
    let data = try Data(contentsOf: url)
    return String(data: data, encoding: .utf8)
        ?? String(data: data, encoding: .utf16)
}

/// Why an outside-world SVG was refused, carrying a user-facing explanation.
/// Detection/predicate sites stay on the silent `ingestSVG`; only deliberate
/// user actions (drop, file open) need the reason so they can explain instead
/// of silently dropping the file.
enum SVGIngestError: Error {
    case tooLarge(bytes: Int)
    case notSVG
    case unsafe

    var userMessage: String {
        switch self {
        case .tooLarge(let bytes):
            // Report the file's own size as well as the limit — users diagnose
            // this by size ("it's 80 MB"), so the actual number is what helps.
            let mb = max(1, Int((Double(bytes) / 1_048_576.0).rounded()))
            return String(
                format: NSLocalizedString(
                    "error.svg.too_large",
                    comment: "Error when a dropped/opened SVG is over the size limit; first %d is the file size in MB, second %d is the limit in MB"),
                mb, maxSVGBytes / (1024 * 1024))
        case .notSVG:
            return NSLocalizedString(
                "error.svg.not_svg",
                comment: "Error when a dropped/opened file is not a usable SVG")
        case .unsafe:
            return NSLocalizedString(
                "error.svg.unsafe",
                comment: "Error when an SVG is blocked for scripts or external references")
        }
    }
}

/// Like `ingestSVG`, but reports why the SVG was refused so deliberate user
/// actions can surface the reason. Same size cap and content screen.
func checkedIngestSVG(_ string: String) -> Result<String, SVGIngestError> {
    // Content is screened before the size check — a large hostile SVG is
    // still hostile and should be reported as such. But the case-insensitive
    // scans in validateSVG cost roughly a second per MB, so running them over
    // an oversized payload would stall ingest for the better part of a minute
    // on a 50 MB clipboard — only to reject the content anyway. For oversized
    // input, screen a bounded prefix instead: hostile markers (scripts, event
    // handlers, external hrefs) cluster near the document head, and both
    // verdicts reject; only the reported reason differs.
    let oversized = string.utf8.count > maxSVGBytes
    let screened = oversized ? String(string.prefix(1_048_576)) : string
    switch validateSVG(screened) {
    case .containsDangerousContent:
        return .failure(.unsafe)
    case .empty, .notSVGElement:
        // A prefix can't prove the full string lacks an <svg> element — for
        // oversized input the size rejection below is the accurate verdict.
        if !oversized { return .failure(.notSVG) }
    case nil:
        break
    }
    guard !oversized else {
        return .failure(.tooLarge(bytes: string.utf8.count))
    }
    return .success(addSVGMargin(string))
}

// MARK: - SVG Processing Utilities

/// Extract SVG dimensions from SVG string
func extractSVGDimensions(svgString: String) -> (width: Double, height: Double)? {
    // Look for viewBox attribute first (more reliable)
    if let viewBoxRange = svgString.range(
        of: "viewBox=[\"']([^\"']+)[\"']", options: .regularExpression)
    {
        let viewBoxValue = String(svgString[viewBoxRange])
        let cleanValue = String(viewBoxValue.dropFirst(9).dropLast(1))
        // The spec allows whitespace and/or commas between viewBox numbers.
        let parts = cleanValue.split(whereSeparator: { $0 == "," || $0.isWhitespace })
        if parts.count >= 4,
            let w = Double(parts[2]), let h = Double(parts[3])
        {
            return (w, h)
        }
    }

    // Fallback: look for width and height attributes
    var width: Double?
    var height: Double?

    if let widthRange = svgString.range(
        of: "width=[\"']([^\"']+)[\"']", options: .regularExpression)
    {
        width = Double(String(svgString[widthRange]).dropFirst(7).dropLast(1))
    }
    if let heightRange = svgString.range(
        of: "height=[\"']([^\"']+)[\"']", options: .regularExpression)
    {
        height = Double(String(svgString[heightRange]).dropFirst(8).dropLast(1))
    }

    if let w = width, let h = height {
        return (w, h)
    }

    return nil
}

/// Get file size in human-readable, locale-aware format
func getFileSizeString(svgString: String) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useBytes, .useKB, .useMB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(svgString.utf8.count))
}

/// Extract creator/application from SVG metadata
func extractSVGCreator(svgString: String) -> String? {
    // Look for common creator attributes
    let patterns = [
        "<!--.*?Creator:\\s*([^-]+)-->",  // SVG comment format
        "<meta\\s+name=[\"']creator[\"']\\s+content=[\"']([^\"']+)[\"']",
        "application-name=[\"']([^\"']+)[\"']",
        "Creator:\\s*([^\\n<]+)",
    ]

    for pattern in patterns {
        if let range = svgString.range(of: pattern, options: .regularExpression) {
            let match = String(svgString[range])
            // Try to extract the actual value
            if let valueRange = match.range(
                of: ":\\s*(.+?)(?:[\"']|-->|<|$)", options: .regularExpression)
            {
                // range(of:) spans the whole match including the terminator
                // ("-->" or "<"), which the character-set trim below can't
                // remove — strip it first or it leaks into the result.
                let value = String(match[valueRange])
                    .replacingOccurrences(
                        of: "\\s*(?:-->|<)$", with: "", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ": \"'"))
                if !value.isEmpty && value != "Creator" {
                    return value
                }
            }
        }
    }

    return nil
}

// MARK: - Content-Derived Naming

/// Only the head of the document is scanned for name hints. Titles, Inkscape
/// docnames, and metadata cluster near the root, so the cap loses almost
/// nothing while keeping naming O(1) even at the 50 MB payload limit.
private let nameHintScanLimit = 64 * 1024

/// Default docnames and placeholders that say nothing about the artwork.
/// A hint made up entirely of these words is rejected so the random-name
/// fallback (which at least guarantees variety) takes over.
private let genericNameHintWords: Set<String> = [
    "untitled", "unbenannt", "sintitulo", "drawing", "zeichnung", "dibujo",
    "image", "bild", "imagen", "document", "dokument", "documento",
    "vector", "graphic", "layer", "svg", "pdf", "export", "new", "neu",
]

/// Reduces a raw name hint to a safe file-name stem: decodes the standard
/// XML entities, drops a recognizable vector-file extension, keeps Unicode
/// letters and digits, joins up to four words with dashes, and caps the
/// length. Returns nil when nothing meaningful remains (placeholder names,
/// pure punctuation, all-generic words).
func sanitizeNameHint(_ raw: String) -> String? {
    var s = raw
    for (entity, char) in [
        ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
    ] {
        s = s.replacingOccurrences(of: entity, with: char)
    }
    s = s.replacingOccurrences(
        of: "\\.(svg|svgz|pdf|ai|eps)\\s*$", with: "",
        options: [.regularExpression, .caseInsensitive])

    let words = s.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        .prefix(4).map(String.init)
    guard words.contains(where: { !genericNameHintWords.contains($0.lowercased()) })
    else { return nil }

    var name = String(words.joined(separator: "-").prefix(40))
    while name.hasSuffix("-") { name.removeLast() }
    guard name.count >= 3, name.contains(where: \.isLetter) else { return nil }
    return name
}

/// Derives a human-meaningful file-name stem from the SVG's own content.
/// Tiers: author-intended metadata first (`<title>`, Inkscape's
/// `sodipodi:docname`, Dublin Core `<dc:title>`, `<desc>`), then the first
/// words of visible `<text>` content — the way document apps name a file
/// after its opening line. Returns nil when nothing usable is found.
/// The result is already sanitized for use as a file name.
func extractSVGNameHint(svgString: String) -> String? {
    let head = String(svgString.prefix(nameHintScanLimit))

    let metadataPatterns = [
        "<title[^>]*>([^<]+)</title>",
        "sodipodi:docname\\s*=\\s*[\"']([^\"']+)[\"']",
        "<dc:title[^>]*>([^<]+)</dc:title>",
        "<desc[^>]*>([^<]+)</desc>",
    ]
    for pattern in metadataPatterns {
        if let hint = firstRegexCapture(of: pattern, in: head),
            let name = sanitizeNameHint(hint)
        { return name }
    }

    // <text> content is often nested in <tspan>s — flatten tags to spaces
    // before sanitizing. The 500-char cap bounds pathological text blocks.
    if let block = firstRegexCapture(of: "<text[^>]*>(.{1,500}?)</text>", in: head) {
        let plain = block.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: .regularExpression)
        return sanitizeNameHint(plain)
    }
    return nil
}

/// First capture group of the first match, or nil. (String.range(of:) can't
/// return capture groups, hence NSRegularExpression.)
private func firstRegexCapture(of pattern: String, in text: String) -> String? {
    guard
        let re = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    else { return nil }
    let whole = NSRange(text.startIndex..., in: text)
    guard let m = re.firstMatch(in: text, range: whole), m.numberOfRanges > 1,
        let r = Range(m.range(at: 1), in: text)
    else { return nil }
    return String(text[r])
}

// MARK: - SVG Canvas Expansion

/// Expands the viewBox (and matching width/height attributes) by `margin`
/// on every side, preventing strokes and fills at the document edge from
/// being clipped when the SVG is rasterized by a host application.
///
/// Called on every Inkscape conversion result: Inkscape sizes the viewBox to
/// the PDF page boundary exactly, so content that touches the edge is cut off.
/// A 5-unit margin is imperceptible at typical slide sizes yet large enough
/// to protect against even a 10 pt stroke centred on the edge.
func addSVGMargin(_ svg: String, margin: Double = 5) -> String {
    guard margin > 0 else { return svg }

    // Locate the opening <svg … > tag.
    guard let svgStart = svg.range(of: "<svg") else { return svg }
    let searchRange = svgStart.upperBound..<svg.endIndex
    guard let tagClose = svg.range(of: ">", range: searchRange) else { return svg }
    let tagRange = svgStart.lowerBound..<tagClose.upperBound
    var tag = String(svg[tagRange])

    // Extract viewBox="x y w h" (or single-quoted variant).
    guard let vbAttrRange = tag.range(of: #"viewBox=["'][^"']+["']"#, options: .regularExpression)
    else { return svg }
    let vbAttr = String(tag[vbAttrRange])
    // The spec allows whitespace and/or commas between viewBox numbers.
    let vbParts = vbAttr
        .components(separatedBy: CharacterSet(charactersIn: "\"'"))
        .first { !$0.isEmpty && ($0.contains(" ") || $0.contains(",")) }
        .flatMap {
            $0.split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .compactMap { Double($0) }
        }
    guard let parts = vbParts, parts.count == 4 else { return svg }

    let newX = parts[0] - margin
    let newY = parts[1] - margin
    let newW = parts[2] + margin * 2
    let newH = parts[3] + margin * 2

    func fmt(_ n: Double) -> String { String(format: "%g", n) }

    tag = tag.replacingOccurrences(
        of: #"viewBox=["'][^"']+["']"#,
        with: "viewBox=\"\(fmt(newX)) \(fmt(newY)) \(fmt(newW)) \(fmt(newH))\"",
        options: .regularExpression)

    // Grow width and height by the same amounts so the aspect ratio is preserved.
    for (attr, newVal) in [("width", newW), ("height", newH)] {
        tag = tag.replacingOccurrences(
            of: "\\b\(attr)=[\"'][0-9][^\"']*[\"']",
            with: "\(attr)=\"\(fmt(newVal))\"",
            options: .regularExpression)
    }

    return svg.replacingCharacters(in: tagRange, with: tag)
}

// MARK: - Keynote SVG Sanitization

/// Strips elements that Keynote's SVG importer rejects.
///
/// Keynote returns "The image type is not supported on this device" when the
/// SVG contains a `<color-profile>` element — the ICC profile metadata that
/// Inkscape (and some Illustrator export paths) embeds to declare the document
/// colour space.  The element is pure metadata; removing it is safe because
/// colours render identically in the sRGB fallback Keynote uses anyway.
func sanitizeSVGForKeynote(_ svg: String) -> String {
    var result = svg
    // Self-closing form: <color-profile ... />   (Inkscape / Illustrator exports)
    result = result.replacingOccurrences(
        of: "<color-profile[^>]*/>",
        with: "",
        options: .regularExpression)
    // Element form: <color-profile ...>…</color-profile>   (rare, but handle it)
    result = result.replacingOccurrences(
        of: "<color-profile[\\s\\S]*?</color-profile>",
        with: "",
        options: .regularExpression)
    return result
}

// MARK: - SVG Normalization

/// Normalise the <svg> root tag so CSS can scale it correctly:
/// • If no viewBox exists but width/height do, synthesise one.
/// • Strip inline width/height so the CSS 100% dimensions take effect.
private func normaliseSVGRootTag(_ svgString: String) -> String {
    guard let startRange = svgString.range(of: "<svg") else { return svgString }
    let afterOpen = startRange.upperBound..<svgString.endIndex
    guard let endRange = svgString.range(of: ">", range: afterOpen) else { return svgString }
    let tagRange = startRange.lowerBound..<endRange.upperBound

    // Extract attribute values with a tiny regex helper.
    func attr(_ name: String, in tag: String) -> String? {
        let pattern = "\(name)=[\"']([^\"']*)[\"']"
        guard let r = tag.range(of: pattern, options: .regularExpression) else { return nil }
        let raw = String(tag[r])  // e.g. width="120"
        let inner = raw.dropFirst(name.count + 2).dropLast(1)  // strip name=" and trailing "
        return String(inner)
    }

    let oldTag = String(svgString[tagRange])
    let viewBox = attr("viewBox", in: oldTag)
    let w = attr("width", in: oldTag)
    let h = attr("height", in: oldTag)

    var newTag = oldTag
    // Synthesise viewBox from width/height if needed.
    if viewBox == nil, let w = w, let h = h,
        !w.hasSuffix("%"), !h.hasSuffix("%")
    {
        // Strip any CSS unit suffix (px, pt, mm, cm, em, …) so that the
        // viewBox contains bare numbers.  "80px" → "80", "210mm" → "210".
        // viewBox values must be unitless; a value like "0 0 80px 80px" is
        // invalid and WebKit ignores it, leaving content unscaled.
        let wNum = String(w.prefix(while: { $0.isNumber || $0 == "." || $0 == "-" }))
        let hNum = String(h.prefix(while: { $0.isNumber || $0 == "." || $0 == "-" }))
        if !wNum.isEmpty, !hNum.isEmpty, wNum != "0", hNum != "0" {
            let vb = "viewBox=\"0 0 \(wNum) \(hNum)\""
            newTag = newTag.replacingOccurrences(
                of: "[\\s]+viewBox=[\"'][^\"']*[\"']", with: "", options: .regularExpression)
            // Insert viewBox before the closing >
            newTag = String(newTag.dropLast()) + " \(vb)>"
        }
    }
    // Strip inline width and height so CSS can drive sizing.
    newTag = newTag.replacingOccurrences(
        of: "\\s+width=[\"'][^\"']*[\"']", with: "", options: .regularExpression)
    newTag = newTag.replacingOccurrences(
        of: "\\s+height=[\"'][^\"']*[\"']", with: "", options: .regularExpression)

    if newTag == oldTag { return svgString }
    return svgString.replacingCharacters(in: tagRange, with: newTag)
}

/// Wrap SVG with responsive HTML/CSS to fill container
func wrapSVGForResponsiveDisplay(svgString: String) -> String {
    let normalisedSVG = normaliseSVGRootTag(svgString)
    return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <style>
                * { margin: 0; padding: 0; }
                html, body {
                    overflow: hidden;
                    background: repeating-conic-gradient(#e8e8e8 0% 25%, #ffffff 0% 50%) 0 0 / 20px 20px;
                }
                @media (prefers-color-scheme: dark) {
                    html, body {
                        background: repeating-conic-gradient(#2a2a2a 0% 25%, #202020 0% 50%) 0 0 / 20px 20px;
                    }
                }
                /* Target only the root SVG (direct child of body) so nested
                   <svg> elements inside the document aren't affected.
                   position:fixed bypasses document-flow height chains and
                   vh/vw timing issues.  The 8 px inset on every side gives
                   the graphic breathing room inside the preview well without
                   affecting the underlying SVG data.  !important overrides
                   any inline style="width/height" from the source app. */
                body > svg {
                    position: fixed !important;
                    top: 8px !important; left: 8px !important;
                    right: 8px !important; bottom: 8px !important;
                    width: calc(100% - 16px) !important;
                    height: calc(100% - 16px) !important;
                }
            </style>
        </head>
        <body>
            \(normalisedSVG)
        </body>
        </html>
        """
}

/// Wrap SVG in minimal HTML sized to its native dimensions for PDF export.
/// No background, no padding — the page is exactly the SVG's bounding box.
func wrapSVGForExport(svgString: String, width: Double, height: Double) -> String {
    let normalisedSVG = normaliseSVGRootTag(svgString)
    return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <style>
                * { margin: 0; padding: 0; }
                html, body {
                    width: \(width)px;
                    height: \(height)px;
                    overflow: hidden;
                    background: transparent;
                }
                body > svg {
                    width: \(width)px !important;
                    height: \(height)px !important;
                }
            </style>
        </head>
        <body>
            \(normalisedSVG)
        </body>
        </html>
        """
}
