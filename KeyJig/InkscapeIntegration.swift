import Cocoa
import Foundation

// MARK: - Inkscape Integration

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
    task.arguments = [
        "--export-type=svg",
        "--export-plain-svg",
        "--export-filename",
        outputURL.path,
        inputURL.path,
    ]

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
        try? FileManager.default.removeItem(at: inputURL)
        DispatchQueue.main.async { completion(svg) }
    }
}

/// Synchronous Inkscape conversion of an arbitrary file (PDF, AI, etc.) to SVG.
/// Convenience wrapper around convertToSVGWithInkscape for use in drop handling.
func convertFileToSVGWithInkscape(url: URL) -> String? {
    return convertToSVGWithInkscape(inputURL: url)
}

// MARK: - Clipboard PDF Extraction

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
