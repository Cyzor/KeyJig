import Cocoa
import Foundation
import os

private let log = Logger(subsystem: "com.cyzor.KeyJig", category: "Inkscape")

// MARK: - Inkscape Integration

/// Filesystem locations we probe for an Inkscape binary, in priority order:
/// the GUI app bundle first, then Apple Silicon Homebrew, then Intel Homebrew.
let inkscapeCandidatePaths: [String] = [
    "/Applications/Inkscape.app/Contents/MacOS/inkscape",
    "/opt/homebrew/bin/inkscape",
    "/usr/local/bin/inkscape",
]

// MARK: - External Tool Probes

private let ghostscriptCandidatePaths = [
    "/opt/homebrew/bin/gs",
    "/usr/local/bin/gs",
    "/opt/local/bin/gs",
]

private let mutoolCandidatePaths = [
    "/opt/homebrew/bin/mutool",
    "/usr/local/bin/mutool",
]

func ghostscriptURL() -> URL? {
    ghostscriptCandidatePaths.lazy
        .map { URL(fileURLWithPath: $0) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

func mutoolURL() -> URL? {
    mutoolCandidatePaths.lazy
        .map { URL(fileURLWithPath: $0) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

// MARK: - Inkscape Probe

/// Returns the path to the first Inkscape executable found on this machine,
/// or nil if Inkscape is not installed. Not cached — re-probed on each call
/// so that an Inkscape install performed mid-session is picked up.
func inkscapeURL() -> URL? {
    for path in inkscapeCandidatePaths
    where FileManager.default.isExecutableFile(atPath: path) {
        return URL(fileURLWithPath: path)
    }
    return nil
}

/// Returns all Inkscape executables found on this machine.
func allInkscapeURLs() -> [URL] {
    inkscapeCandidatePaths.compactMap { path in
        FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
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

    // Inkscape is chatty on stdout/stderr even on success. We don't surface
    // its output to the user — failures are signalled via a non-zero exit
    // and a nil return, which the caller logs and translates into the UI's
    // generic "conversion failed" state. If you need to debug a specific
    // Inkscape invocation, swap these for `Pipe()` and read after exit.
    task.standardError = FileHandle.nullDevice
    task.standardOutput = FileHandle.nullDevice

    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        log.error("Inkscape launch failed: \(error.localizedDescription, privacy: .public)")
        return nil
    }

    guard task.terminationStatus == 0 else {
        log.error("Inkscape exited with status \(task.terminationStatus, privacy: .public)")
        return nil
    }

    guard let svg = try? String(contentsOf: outputURL, encoding: .utf8),
          svg.contains("<svg")
    else {
        try? FileManager.default.removeItem(at: outputURL)
        return nil
    }
    try? FileManager.default.removeItem(at: outputURL)
    return addSVGMargin(svg)
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
            log.error("failed to write temp PDF: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let svg = convertToSVGWithInkscape(inputURL: inputURL)
        try? FileManager.default.removeItem(at: inputURL)
        DispatchQueue.main.async { completion(svg) }
    }
}

