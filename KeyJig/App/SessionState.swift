import Foundation

// MARK: - Session Files

/// Writes and reads per-session SVG snapshots for windows whose content
/// came from the clipboard (no on-disk file URL of the user's own).
enum SessionFiles {
    static var directory: URL {
        let id = Bundle.main.bundleIdentifier ?? "com.cyzor.KeyJig"
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(id + "/session")
    }

    /// Writes `svg` to a stable named slot under the session directory.
    /// Returns the file URL on success, nil on write failure.
    static func write(_ svg: String, slot name: String) -> URL? {
        let dir = directory
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name + ".svg")
        return (try? svg.write(to: url, atomically: true, encoding: .utf8)) == nil
            ? nil : url
    }

    static func isSessionFile(_ url: URL) -> Bool {
        url.path.hasPrefix(directory.path)
    }
}

// MARK: - Codable Helpers

/// Codable wrapper around NSRect.
struct CodableRect: Codable {
    var x, y, w, h: Double
    init(_ r: NSRect) {
        x = Double(r.origin.x); y = Double(r.origin.y)
        w = Double(r.size.width); h = Double(r.size.height)
    }
    var nsRect: NSRect { NSRect(x: x, y: y, width: w, height: h) }
}

// MARK: - Window Entry

/// State for one document window.
struct WindowEntry: Codable {
    /// User's original file path, or a SessionFiles snapshot path.  nil = empty window.
    var contentURL: String?
    /// Frame of the window at quit time.
    var frame: CodableRect
    /// Windows sharing the same non-nil tabGroupID are part of one tab bar.
    var tabGroupID: Int?
    /// True when this window was the selected (frontmost) tab in its group at quit time.
    var isSelectedTab: Bool

    init(contentURL: String?, frame: CodableRect, tabGroupID: Int?, isSelectedTab: Bool = false) {
        self.contentURL = contentURL
        self.frame = frame
        self.tabGroupID = tabGroupID
        self.isSelectedTab = isSelectedTab
    }

    // Custom decoder so old session records missing `isSelectedTab` still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contentURL    = try c.decodeIfPresent(String.self,  forKey: .contentURL)
        frame         = try c.decode(CodableRect.self,       forKey: .frame)
        tabGroupID    = try c.decodeIfPresent(Int.self,      forKey: .tabGroupID)
        isSelectedTab = (try? c.decode(Bool.self, forKey: .isSelectedTab)) ?? false
    }
}

// MARK: - Session State

/// Persists the complete window arrangement at last quit. Stored as JSON in UserDefaults.
struct SessionState: Codable {
    /// All document windows in creation order; index 0 is always the primary window.
    var windows: [WindowEntry]

    static let defaultsKey = "SessionState"

    static func load() -> SessionState? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: SessionState.defaultsKey)
        }
    }
}
