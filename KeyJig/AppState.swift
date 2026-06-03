import Combine
import Foundation
import SwiftUI
import AppKit

// MARK: - App State

/// Tracks SVG content and conversion state for a single window or popover.
/// Each window owns its own AppState — changes in one window never affect another.
class AppState: ObservableObject {
    @Published var svgURL: String = ""
    @Published var svgString: String = "" {
        didSet {
            // Loading any SVG content takes over the preview — clear any
            // active "Pull from Keynote" PDF so the two modes don't coexist.
            if !svgString.isEmpty && previewPDFURL != nil {
                previewPDFURL = nil
            }
        }
    }
    /// The last temp file written by svgToClipboard() or an outbound drag.
    /// Stored here so the proxy icon can find it even though each write now
    /// produces a uniquely-named file.
    @Published var bridgeFileURL: URL? = nil
    /// Tracks background PDF→SVG conversion so the UI can show feedback.
    @Published var conversionStatus: ConversionStatus = .idle
    /// Tracks Inkscape installation status and all available paths.
    @Published var inkscapeStatus: InkscapeStatus = .checking
    /// Tracks in-progress / result state for the "Place in Keynote" action.
    @Published var keynoteSendStatus: KeynoteSendStatus = .idle
    /// When non-nil, the preview shows this PDF instead of an SVG. Set by
    /// "Pull from Keynote"; setting it clears `svgString`, and vice versa.
    @Published var previewPDFURL: URL? = nil {
        didSet {
            if previewPDFURL != nil && !svgString.isEmpty {
                svgString = ""
                svgURL = ""
            }
        }
    }
    /// Tracks in-progress / result state for the "Pull from Keynote" action.
    @Published var keynotePullStatus: KeynotePullStatus = .idle
    /// Change count of the last pasteboard snapshot we acted on. Used by
    /// checkAndLoadClipboardSVG to skip re-processing an unchanged clipboard.
    var lastLoadedClipboardChangeCount: Int = -1

    /// The minimum width needed to display the button area without truncation,
    /// measured by ContentView's invisible probe during its first layout pass.
    /// MainWindowController observes this and applies it as contentMinSize.width.
    @Published var minimumButtonAreaWidth: CGFloat = 0

    /// The transient status/error string shown below the preview. Updated by
    /// button actions and menu commands alike. Empty means "show default state".
    @Published var statusMessage: String = ""

    /// True when the clipboard contains Keynote-native object data (the type
    /// written by Keynote when you ⌘C canvas objects). Drives the enabled
    /// state of the "Convert Keynote Clipboard to PDF" button.
    @Published var keynoteClipboardReady: Bool = false

    /// True when Keynote is running. Drives the enabled state of the
    /// "Convert Keynote Slide to PDF" button. Does not check for open
    /// documents — the existing error message handles that case.
    @Published var keynoteRunning: Bool = false

    private var clipboardTimer: Timer?
    private var workspaceObservers: [Any] = []
    private var lastSeenClipboardChangeCount: Int = -1

    init() {
        checkInkscapeStatus()
        startKeynoteMonitoring()
    }

    deinit {
        clipboardTimer?.invalidate()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    private func startKeynoteMonitoring() {
        // ── Keynote running state ─────────────────────────────────────────
        // Seed current state, then track via workspace notifications (zero
        // polling cost).
        keynoteRunning = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.iWork.Keynote")
            .first != nil

        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                    app.bundleIdentifier == "com.apple.iWork.Keynote" else { return }
                self?.keynoteRunning = true
        })
        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                    app.bundleIdentifier == "com.apple.iWork.Keynote" else { return }
                self?.keynoteRunning = false
        })

        // ── Clipboard monitoring ──────────────────────────────────────────
        // Poll changeCount every 0.5 s — only evaluates pasteboard types when
        // the count has actually moved, so the steady-state cost is one int
        // comparison per tick.
        checkClipboardForKeynoteData()   // seed immediately
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboardForKeynoteData()
        }
    }

    private func checkClipboardForKeynoteData() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastSeenClipboardChangeCount else { return }
        lastSeenClipboardChangeCount = count
        // Keynote writes types containing "keynote" or "iWork" when canvas
        // objects are copied. This excludes plain PDFs, images, and text that
        // other apps write — those don't round-trip as native vector objects.
        let ready = (pb.types ?? []).contains { t in
            t.rawValue.localizedCaseInsensitiveContains("keynote") ||
            t.rawValue.localizedCaseInsensitiveContains("iWork")
        }
        if keynoteClipboardReady != ready {
            keynoteClipboardReady = ready
        }
    }

    private func checkInkscapeStatus() {
        DispatchQueue.global(qos: .userInitiated).async {
            let paths = allInkscapeURLs().map(\.path)
            DispatchQueue.main.async {
                if paths.isEmpty {
                    self.inkscapeStatus = .notInstalled
                } else {
                    self.inkscapeStatus = .installed(paths: paths)
                }
            }
        }
    }
}

// MARK: - Supporting Types

enum ConversionStatus: Equatable {
    case idle
    case converting
    case failed
}

enum KeynoteSendStatus: Equatable {
    case idle
    case sending
    case succeeded
    case failed
}

enum KeynotePullStatus: Equatable {
    case idle
    case pulling
    case succeeded
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
/// "Adjective-Noun-Vector-YYYY-MM-DD.svg".
func makeTempSVGURL() -> URL {
    let adj = _adjectives.randomElement() ?? "Vector"
    let noun = _nouns.randomElement() ?? "File"
    let date = {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }()
    let name = "\(adj)-\(noun)-Vector-\(date).svg"
    return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
}
