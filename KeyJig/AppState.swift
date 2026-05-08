import Combine
import Foundation
import SwiftUI

// MARK: - App State

/// Tracks SVG content and conversion state for a single window or popover.
/// Each window owns its own AppState — changes in one window never affect another.
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

// MARK: - Supporting Types

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

// MARK: - Limits

/// Upper bound on SVG payload size we will write to the pasteboard or to a
/// temp file. Keynote's importer struggles with multi-megabyte SVGs, and
/// passing very large strings through `String.write(to:)` and the pasteboard
/// risks blocking the UI. 50 MB is generous in practice; legitimate vector
/// art is almost always under 1 MB.
let maxSVGBytes = 50 * 1024 * 1024

// MARK: - Temp File Naming

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

/// Generates a unique temp-file URL with a human-readable name of the form
/// "Adjective-Noun-Vector-YYYY-MM-DD.svg". `SecRandomCopyBytes` is used purely
/// as a uniform random source for the word picks — there is no secrecy
/// requirement; a weaker PRNG would do, but `SecRandomCopyBytes` ships with
/// the system and avoids pulling in `arc4random_uniform` quirks.
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
