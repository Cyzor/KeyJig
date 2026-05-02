import Foundation

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
    let dangerousPatterns = [
        "<script", "javascript:", "onerror=", "onclick=",
        "onload=", "onmouseover=", "xlink:href=[\"']https?://",
    ]
    for pattern in dangerousPatterns {
        if string.range(of: pattern, options: .caseInsensitive) != nil {
            return .containsDangerousContent
        }
    }
    return nil
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
        let parts = cleanValue.split(separator: " ")
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
                let value = String(match[valueRange]).trimmingCharacters(
                    in: CharacterSet(charactersIn: ": \"'"))
                if !value.isEmpty && value != "Creator" {
                    return value
                }
            }
        }
    }

    return nil
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
                html, body { overflow: hidden; background: transparent; }
                /* Target only the root SVG (direct child of body) so nested
                   <svg> elements inside the document aren't affected.
                   position:fixed + four zero offsets sizes relative to the
                   WKWebView viewport, bypassing all document-flow height chains
                   and vh/vw timing issues.  !important overrides any inline
                   style="width/height" left by the originating application. */
                body > svg {
                    position: fixed !important;
                    top: 0 !important; left: 0 !important;
                    right: 0 !important; bottom: 0 !important;
                    width: 100% !important; height: 100% !important;
                }
            </style>
        </head>
        <body>
            \(normalisedSVG)
        </body>
        </html>
        """
}
