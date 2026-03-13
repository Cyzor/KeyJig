import Cocoa
import SwiftUI

enum ConversionStatus: Equatable {
    case idle
    case converting
    case failed
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
        svgString.contains("<svg")
    {
        return svgString
    }

    // 2. Raw SVG text on the string pasteboard
    if let content = pasteboard.string(forType: .string), content.contains("<svg") {
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
    let adj = _adjectives[Int(arc4random_uniform(UInt32(_adjectives.count)))]
    let noun = _nouns[Int(arc4random_uniform(UInt32(_nouns.count)))]
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
    let tempFile = makeTempSVGURL()
    do {
        try svgData.write(to: tempFile, atomically: true, encoding: .utf8)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([tempFile as NSURL])
        appState?.bridgeFileURL = tempFile
        return tempFile
    } catch {
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

/// Returns the path to the first Inkscape executable found on this machine,
/// or nil if Inkscape is not installed.  Result is cached after the first call.
func inkscapeURL() -> URL? {
    let candidates = [
        "/Applications/Inkscape.app/Contents/MacOS/inkscape",
        "/opt/homebrew/bin/inkscape",
        "/usr/local/bin/inkscape",
    ]
    for path in candidates {
        if FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
    }
    return nil
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
        "--export-filename=\(outputURL.path)",
        inputURL.path,
    ]

    // Suppress Inkscape's verbose stderr so it doesn't pollute the console.
    task.standardError = FileHandle.nullDevice
    task.standardOutput = FileHandle.nullDevice

    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        NSLog("VectorImporter: Inkscape launch failed: \(error)")
        return nil
    }

    guard task.terminationStatus == 0 else {
        NSLog("VectorImporter: Inkscape exited with status \(task.terminationStatus)")
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
            NSLog("VectorImporter: failed to write temp PDF: \(error)")
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
func extractSVGDimensions(svgString: String) -> (width: String, height: String)? {
    // Look for viewBox attribute first (more reliable)
    if let viewBoxRange = svgString.range(
        of: "viewBox=[\"']([^\"']+)[\"']", options: .regularExpression)
    {
        let viewBoxValue = String(svgString[viewBoxRange])
        let cleanValue = String(viewBoxValue.dropFirst(9).dropLast(1))
        let parts = cleanValue.split(separator: " ")
        if parts.count >= 4 {
            return (String(parts[2]), String(parts[3]))
        }
    }

    // Fallback: look for width and height attributes
    var width: String?
    var height: String?

    if let widthRange = svgString.range(
        of: "width=[\"']([^\"']+)[\"']", options: .regularExpression)
    {
        let widthValue = String(svgString[widthRange])
        width = String(widthValue.dropFirst(7).dropLast(1))
    }
    if let heightRange = svgString.range(
        of: "height=[\"']([^\"']+)[\"']", options: .regularExpression)
    {
        let heightValue = String(svgString[heightRange])
        height = String(heightValue.dropFirst(8).dropLast(1))
    }

    if let w = width, let h = height {
        return (w, h)
    }

    return nil
}

// Get file size in human-readable format
func getFileSizeString(svgString: String) -> String {
    let bytes = svgString.utf8.count

    if bytes < 1024 {
        return "\(bytes) B"
    } else if bytes < 1024 * 1024 {
        let kb = Double(bytes) / 1024.0
        return String(format: "%.1f KB", kb)
    } else {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }
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

// Wrap SVG with responsive HTML/CSS to fill container
func wrapSVGForResponsiveDisplay(svgString: String) -> String {
    return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <style>
                * {
                    margin: 0;
                    padding: 0;
                    box-sizing: border-box;
                }
                html, body {
                    width: 100%;
                    height: 100%;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    background: transparent;
                }
                svg {
                    width: 100%;
                    height: 100%;
                    max-width: 100%;
                    max-height: 100%;
                    object-fit: contain;
                }
            </style>
        </head>
        <body>
            \(svgString)
        </body>
        </html>
        """
}
