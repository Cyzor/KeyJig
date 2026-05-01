import Cocoa
import Security
import SwiftUI

enum ConversionStatus: Equatable {
    case idle
    case converting
    case failed
}

enum InkscapeStatus: Equatable {
    case checking
    case installed(paths: [String])  // All found installations
    case notInstalled
}

class AppState: ObservableObject {
    @Published var svgURL: String = ""
    @Published var svgString: String = ""
    /// The last temp file written by svgToClipboard() or an outbound drag.
    /// Stored here so the proxy icon can find it even though each write now
    /// produces a uniquely-named file.
    @Published var bridgeFileURL: URL? = nil
    /// Tracks background PDF→SVG conversion so the UI can show feedback.
    @Published var conversionStatus: ConversionStatus = .idle
    /// Tracks Inkscape installation status and all available paths.
    @Published var inkscapeStatus: InkscapeStatus = .checking

    init() {
        checkInkscapeStatus()
    }

    private func checkInkscapeStatus() {
        DispatchQueue.global(qos: .userInitiated).async {
            let paths = self.allInkscapePaths()
            DispatchQueue.main.async {
                if paths.isEmpty {
                    self.inkscapeStatus = .notInstalled
                } else {
                    self.inkscapeStatus = .installed(paths: paths)
                }
            }
        }
    }

    private func allInkscapePaths() -> [String] {
        let candidates = [
            "/Applications/Inkscape.app/Contents/MacOS/inkscape",
            "/opt/homebrew/bin/inkscape",
            "/usr/local/bin/inkscape",
        ]
        return candidates.filter { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - Clipboard SVG detection

/// Synchronously checks the clipboard for SVG content.
/// Returns the SVG string if found, empty string otherwise.
/// Fast path only — no subprocesses, no I/O beyond the pasteboard read.
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

// MARK: - Clipboard SVG detection

/// Synchronously checks the clipboard for SVG content.
/// Returns the SVG string if found, empty string otherwise.
/// Fast path only — no subprocesses, no I/O beyond the pasteboard read.
func convertClipboardToSVG() -> String {
    let pasteboard = NSPasteboard.general

    // 1. Explicit SVG data type (Affinity Designer with SVG export enabled,
    //    Inkscape, some web browsers)
    let svgType = NSPasteboard.PasteboardType("public.svg-image")
    if let data = pasteboard.data(forType: svgType),
        let svgString = String(data: data, encoding: .utf8),
        validateSVG(svgString) == nil
    {
        return svgString
    }

    // 2. Raw SVG text on the string pasteboard
    if let content = pasteboard.string(forType: .string),
        validateSVG(content) == nil
    {
        return content
    }

    return ""
}

/// Returns true if the clipboard contains PDF or AICB vector data that could
/// be converted via Inkscape, but no native SVG was found.
/// Used to decide whether to attempt the slow conversion path.
func clipboardHasConvertibleVectorData() -> Bool {
    let pasteboard = NSPasteboard.general
    let types = pasteboard.types ?? []
    let vectorTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("Apple PDF pasteboard type"),
        NSPasteboard.PasteboardType("com.adobe.pdf"),
        NSPasteboard.PasteboardType("com.adobe.illustrator.aicb"),
    ]
    return vectorTypes.contains { types.contains($0) }
}

/// Extracts the best available PDF data from the clipboard.
/// Prefers the Adobe PDF type; falls back to Apple's.
func pdfDataFromClipboard() -> Data? {
    let pasteboard = NSPasteboard.general
    if let data = pasteboard.data(
        forType: NSPasteboard.PasteboardType("com.adobe.pdf")), !data.isEmpty
    {
        return data
    }
    if let data = pasteboard.data(
        forType: NSPasteboard.PasteboardType("Apple PDF pasteboard type")), !data.isEmpty
    {
        return data
    }
    return nil
}

// MARK: - Temp file naming

private let _adjectives: [String] = [
    "Amber", "Ancient", "Angular", "Antique", "Arcane", "Argent", "Astral", "Azure",
    "Bold", "Brass", "Breezy", "Brisk", "Broad", "Burnished",
    "Calm", "Candid", "Cardinal", "Carved", "Cerulean", "Chiseled", "Chromatic", "Cinder",
    "Civic", "Cobalt", "Coiled", "Copper", "Coral", "Crimson", "Crisp", "Crystal",
    "Dark", "Deft", "Dense", "Dim", "Distant", "Dramatic", "Dusk",
    "Ebony", "Elaborate", "Ember", "Emerald", "Etched", "Even",
    "Faded", "Flat", "Fluid", "Formal", "Frosted",
    "Gilded", "Glacial", "Glowing", "Golden", "Graceful", "Grand", "Granite", "Graphic",
    "Hollow", "Honed",
    "Idle", "Indigo", "Inked", "Intricate", "Ivory",
    "Jade", "Jagged",
    "Keen",
    "Lacquered", "Lateral", "Layered", "Lean", "Linen", "Liquid", "Lone", "Lucid", "Lunar",
    "Matte", "Mauve", "Measured", "Midnight", "Mist", "Moody", "Muted",
    "Narrow", "Naval", "Neutral", "Noble",
    "Oblique", "Obsidian", "Ochre", "Onyx", "Opaque", "Open", "Orbital",
    "Pale", "Parallel", "Patina", "Pearl", "Pewter", "Pitch", "Planar", "Plain", "Polished",
    "Prism", "Prismatic",
    "Quiet",
    "Radiant", "Raw", "Rigid", "Rough", "Round", "Royal", "Rugged", "Rustic",
    "Sable", "Sapphire", "Scaled", "Scarlet", "Serene", "Sharp", "Sleek", "Slim", "Smoky",
    "Soft", "Solar", "Solid", "Stark", "Static", "Steel", "Stone", "Storm", "Subtle",
    "Tall", "Tapered", "Teal", "Terse", "Textured", "Tidal", "Tinted", "Trim",
    "Umbral",
    "Vast", "Velvet", "Verdant", "Vivid",
    "Warm", "Wide", "Wiry",
    "Zinc",
]

private let _nouns: [String] = [
    "Albatross", "Alpaca", "Antelope", "Armadillo", "Axolotl",
    "Badger", "Bison", "Boar", "Bobcat", "Bullfrog",
    "Capybara", "Caracal", "Cassowary", "Chameleon", "Cheetah", "Chinchilla", "Chipmunk",
    "Cockatoo", "Condor", "Cormorant", "Coyote", "Crane",
    "Dingo", "Dormouse", "Dugong",
    "Echidna", "Egret", "Eland",
    "Falcon", "Ferret", "Flamingo", "Fossa", "Fulmar",
    "Gavial", "Gecko", "Genet", "Gerbil", "Gibbon", "Goshawk", "Grackle",
    "Hamster", "Harrier", "Hedgehog", "Heron", "Hoopoe", "Hyena",
    "Ibex", "Ibis", "Iguana", "Impala",
    "Jackal", "Jaguar", "Jerboa",
    "Kakapo", "Kangaroo", "Kestrel", "Kinkajou", "Kiwi", "Kookaburra",
    "Lapwing", "Lemur", "Leopard", "Linsang", "Lynx",
    "Marmot", "Meerkat", "Mongoose", "Monitor", "Moose", "Muskrat",
    "Narwhal", "Numbat",
    "Ocelot", "Okapi", "Opossum", "Osprey", "Otter",
    "Pangolin", "Parakeet", "Peccary", "Pelican", "Penguin", "Porcupine", "Puffin",
    "Quetzal", "Quokka",
    "Raccoon", "Raven", "Reedbuck", "Roadrunner",
    "Salamander", "Serval", "Skink", "Sloth", "Snipe", "Springbok", "Stoat", "Sunbird",
    "Tamarin", "Tapir", "Tarsier", "Tenrec", "Terrapene", "Toucan",
    "Uakari",
    "Vicuna", "Vole", "Vulture",
    "Wallaby", "Walrus", "Warthog", "Wolverine", "Wombat",
    "Xerus",
    "Yak",
    "Zebra",
]

/// Generates a unique temp-file URL with a human-readable name of the form
/// "Adjective-Noun-Vector-YYYY-MM-DD.svg".  Uses arc4random for speed —
/// no locking, no seeding, always cryptographically random.
func makeTempSVGURL() -> URL {
    var byte: UInt8 = 0
    _ = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
    let adj = _adjectives[Int(byte) % _adjectives.count]
    _ = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
    let noun = _nouns[Int(byte) % _nouns.count]
    let date = {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }()
    let name = "\(adj)-\(noun)-Vector-\(date).svg"
    return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
}

/// Legacy alias kept so call sites that don't need a stable URL still compile.
/// New writes should call makeTempSVGURL() directly and store the result.
func getTempSVGURL() -> URL {
    return makeTempSVGURL()
}

/// Writes svgData to a freshly-named temp file, places its URL on the
/// pasteboard, and returns the written URL so callers can store it on
/// AppState.bridgeFileURL for the proxy icon.
@discardableResult
func svgToClipboard(svgData: String, appState: AppState? = nil) -> URL? {
    let sizeLimit = 50 * 1024 * 1024  // 50 MB
    guard svgData.utf8.count <= sizeLimit else {
        NSLog("KeyJig: SVG size (\(svgData.utf8.count)) exceeds limit of \(sizeLimit) bytes")
        return nil
    }
    let tempFile = makeTempSVGURL()
    do {
        try svgData.write(to: tempFile, atomically: true, encoding: .utf8)
        // Hardened permissions: owner read/write only (0600)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: tempFile.path
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([tempFile as NSURL])
        appState?.bridgeFileURL = tempFile
        return tempFile
    } catch {
        NSLog("KeyJig: error writing temp SVG: \(error)")
        return nil
    }
}

func pdfToClipboard(pdfData: Data?) -> Bool {
    guard let data = pdfData else { return false }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let adobePdfType = NSPasteboard.PasteboardType("com.adobe.pdf")
    let applePdfType = NSPasteboard.PasteboardType("Apple PDF pasteboard type")
    pasteboard.declareTypes([adobePdfType, applePdfType], owner: nil)
    pasteboard.setData(data, forType: adobePdfType)
    pasteboard.setData(data, forType: applePdfType)
    return true
}

// MARK: - Inkscape integration

private var _cachedInkscapeURL: URL?
private var _inkscapeURLChecked = false
private var _allInkscapeURLsCache: [URL]?
private let _inkscapeLock = NSLock()

/// Returns the path to the first Inkscape executable found on this machine,
/// or nil if Inkscape is not installed. Result is cached after the first call.
/// Thread-safe via NSLock.
func inkscapeURL() -> URL? {
    _inkscapeLock.lock()
    defer { _inkscapeLock.unlock() }
    if _inkscapeURLChecked {
        return _cachedInkscapeURL
    }
    let candidates = [
        "/Applications/Inkscape.app/Contents/MacOS/inkscape",
        "/opt/homebrew/bin/inkscape",
        "/usr/local/bin/inkscape",
    ]
    for path in candidates {
        if FileManager.default.isExecutableFile(atPath: path) {
            _cachedInkscapeURL = URL(fileURLWithPath: path)
            _inkscapeURLChecked = true
            return _cachedInkscapeURL
        }
    }
    _inkscapeURLChecked = true
    return nil
}

/// Returns all Inkscape executables found on this machine.
/// Results are cached after the first call. Thread-safe via NSLock.
func allInkscapeURLs() -> [URL] {
    _inkscapeLock.lock()
    defer { _inkscapeLock.unlock() }
    if let cached = _allInkscapeURLsCache {
        return cached
    }
    let candidates = [
        "/Applications/Inkscape.app/Contents/MacOS/inkscape",
        "/opt/homebrew/bin/inkscape",
        "/usr/local/bin/inkscape",
    ]
    let result = candidates.compactMap { path in
        FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
    _allInkscapeURLsCache = result
    return result
}

/// Converts the given input file to SVG using Inkscape and returns the SVG
/// string, or nil if conversion fails or Inkscape is not installed.
/// Must be called on a background thread — blocks until Inkscape exits.
func convertToSVGWithInkscape(inputURL: URL) -> String? {
    guard let inkscape = inkscapeURL() else { return nil }

    let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("svg")

    let task = Process()
    task.executableURL = inkscape
    // --export-plain-svg produces cleaner output (no Inkscape-specific attributes)
    task.arguments = [
        "--export-type=svg",
        "--export-plain-svg",
        "--export-filename",
        outputURL.path,
        inputURL.path,
    ]

    // Suppress Inkscape's verbose stderr so it doesn't pollute the console.
    task.standardError = FileHandle.nullDevice
    task.standardOutput = FileHandle.nullDevice

    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        NSLog("KeyJig: Inkscape launch failed: \(error)")
        return nil
    }

    guard task.terminationStatus == 0 else {
        NSLog("KeyJig: Inkscape exited with status \(task.terminationStatus)")
        return nil
    }

    let svg = try? String(contentsOf: outputURL, encoding: .utf8)
    // Clean up the temp output file.
    try? FileManager.default.removeItem(at: outputURL)
    return svg?.contains("<svg") == true ? svg : nil
}

/// Asynchronously converts clipboard PDF/AICB data to SVG via Inkscape.
/// Calls `completion` on the main queue with the SVG string, or nil on failure.
/// Should only be called after `convertClipboardToSVG()` has already returned "".
func convertClipboardPDFToSVG(completion: @escaping (String?) -> Void) {
    guard let pdfData = pdfDataFromClipboard() else {
        DispatchQueue.main.async { completion(nil) }
        return
    }

    DispatchQueue.global(qos: .userInitiated).async {
        // Write PDF data to a temp file for Inkscape to read.
        let inputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")

        do {
            try pdfData.write(to: inputURL)
        } catch {
            NSLog("KeyJig: failed to write temp PDF: \(error)")
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let svg = convertToSVGWithInkscape(inputURL: inputURL)
        // Clean up the temp input file.
        try? FileManager.default.removeItem(at: inputURL)
        DispatchQueue.main.async { completion(svg) }
    }
}

/// Synchronous Inkscape conversion of an arbitrary file (PDF, AI, etc.) to SVG.
/// Convenience wrapper around convertToSVGWithInkscape for use in drop handling,
/// which already runs on a background queue via a coordinator.
func convertFileToSVGWithInkscape(url: URL) -> String? {
    return convertToSVGWithInkscape(inputURL: url)
}

// Extract SVG dimensions from SVG string
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

// Get file size in human-readable, locale-aware format
func getFileSizeString(svgString: String) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useBytes, .useKB, .useMB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(svgString.utf8.count))
}

// Extract creator/application from SVG metadata
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

// Normalise the <svg> root tag so CSS can scale it correctly:
// • If no viewBox exists but width/height do, synthesise one.
// • Strip inline width/height so the CSS 100% dimensions take effect.
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

// Wrap SVG with responsive HTML/CSS to fill container
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
