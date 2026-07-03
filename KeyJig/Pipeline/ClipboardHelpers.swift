import Cocoa
import os

private let log = Logger(subsystem: "com.cyzor.KeyJig", category: "Clipboard")

// MARK: - SVG Size Limit

/// Upper bound on SVG payload size we will write to the pasteboard or to a
/// temp file. Keynote's importer struggles with multi-megabyte SVGs, and
/// passing very large strings through `String.write(to:)` and the pasteboard
/// risks blocking the UI. 50 MB is generous in practice; legitimate vector
/// art is almost always under 1 MB.
let maxSVGBytes = 50 * 1024 * 1024

// MARK: - Temp SVG File Naming

// Each call to `svgToClipboard` writes to a freshly-named temp file because
// Keynote will sometimes reuse the URL on the pasteboard rather than re-read
// the contents — if two consecutive imports use the same filename, the second
// silently inserts the first SVG's content. A unique, human-readable name
// (e.g. "Amber-Lemur-Vector-2026-05-08.svg") sidesteps that collision and
// keeps the pasteboard entry self-explanatory if the user inspects it.

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

/// Generates a unique temp-file URL with a human-readable name.
///
/// When the content or its origin yields a meaningful stem the form is
/// "Stem-Vector-YYYY-MM-DD-x7k9.svg". The random suffix is load-bearing:
/// content-derived stems repeat across exports of the same artwork, and a
/// reused file name triggers the Keynote stale-paste bug described above.
/// Without a derivable stem the form stays "Adjective-Noun-Vector-YYYY-MM-DD.svg",
/// whose random word pair already provides the uniqueness.
///
/// Derived stems can contain words from the user's document — never log
/// these file names (per the logging policy, content is private).
func makeTempSVGURL(svg: String? = nil, originPath: String? = nil) -> URL {
    let date = {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }()
    let name: String
    if let stem = derivedNameStem(svg: svg, originPath: originPath) {
        // Unambiguous alphabet (no 0/O/1/l/i) — these names are user-visible.
        let suffix = String((0..<4).compactMap { _ in
            "abcdefghjkmnpqrstuvwxyz23456789".randomElement()
        })
        name = "\(stem)-Vector-\(date)-\(suffix).svg"
    } else {
        let adj = _adjectives.randomElement() ?? "Vector"
        let noun = _nouns.randomElement() ?? "File"
        name = "\(adj)-\(noun)-Vector-\(date).svg"
    }
    return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
}

/// Best meaningful name stem for the content, or nil for the random
/// fallback. Provenance (the file the user opened, tracked in
/// AppState.svgURL) outranks the SVG's self-description — the user chose
/// that name. Both run through the same sanitizer, so a generic origin name
/// ("drawing.svg") falls through to the content tiers.
private func derivedNameStem(svg: String?, originPath: String?) -> String? {
    if let path = originPath, !path.isEmpty,
        let stem = sanitizeNameHint(
            URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
    { return stem }
    if let svg, let stem = extractSVGNameHint(svgString: svg) { return stem }
    return nil
}

// MARK: - Clipboard SVG Detection

/// Synchronously checks the clipboard for SVG content.
/// Returns the SVG string if found, empty string otherwise.
/// Fast path only — no subprocesses, no I/O beyond the pasteboard read.
func convertClipboardToSVG() -> String {
    let pasteboard = NSPasteboard.general

    // 1. Explicit SVG data types, in priority order.
    //    public.svg-image and com.adobe.svg are declared by Illustrator but may
    //    not materialise (no data). The actual payload lives in the proprietary
    //    Adobe types. All four-char-code variants are listed for completeness.
    let svgDataTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("public.svg-image"),
        NSPasteboard.PasteboardType("com.adobe.svg"),
        NSPasteboard.PasteboardType("com.adobe.illustrator.svg"),
        NSPasteboard.PasteboardType("com.adobe.illustrator.svgm"),
        NSPasteboard.PasteboardType("CorePasteboardFlavorType 0x73766720"),  // 'svg '
        NSPasteboard.PasteboardType("CorePasteboardFlavorType 0x53564720"),  // 'SVG '
    ]
    for type in svgDataTypes {
        guard let data = pasteboard.data(forType: type) else { continue }
        let candidate = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
        guard let svgString = candidate, let safe = ingestSVG(svgString) else { continue }
        return safe
    }

    // 2. Raw SVG text on the string pasteboard
    if let content = pasteboard.string(forType: .string),
        let safe = ingestSVG(content)
    {
        return safe
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

// MARK: - Clipboard Write Operations

/// Writes svgData to a freshly-named temp file, places its URL on the
/// pasteboard, and returns the written URL so callers can store it on
/// AppState.bridgeFileURL for the proxy icon.
@discardableResult
func svgToClipboard(svgData: String, appState: AppState? = nil) -> URL? {
    guard svgData.utf8.count <= maxSVGBytes else {
        log.error("SVG size (\(svgData.utf8.count, privacy: .public)) exceeds limit of \(maxSVGBytes, privacy: .public) bytes")
        return nil
    }
    let tempFile = makeTempSVGURL(svg: svgData, originPath: appState?.svgURL)
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
        log.error("error writing temp SVG: \(error.localizedDescription, privacy: .public)")
        return nil
    }
}

// MARK: - PDF Clipboard Read

/// Extracts the best available PDF data from the clipboard.
/// Prefers the Adobe PDF type; falls back to Apple's.
func pdfDataFromClipboard() -> Data? {
    let pasteboard = NSPasteboard.general
    if let data = pasteboard.data(
        forType: NSPasteboard.PasteboardType("com.adobe.pdf")), !data.isEmpty
    { return data }
    if let data = pasteboard.data(
        forType: NSPasteboard.PasteboardType("Apple PDF pasteboard type")), !data.isEmpty
    { return data }
    return nil
}

// MARK: - PDF Clipboard Write

/// Writes PDF data + file URL to the general pasteboard. Returns true on success.
@discardableResult
func pdfToClipboard(url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url) else {
        log.error("could not read PDF for clipboard")
        return false
    }
    let pb = NSPasteboard.general
    pb.clearContents()
    let item = NSPasteboardItem()
    item.setData(data, forType: NSPasteboard.PasteboardType("com.adobe.pdf"))
    item.setString(url.absoluteString, forType: .fileURL)
    pb.writeObjects([item])
    return true
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
