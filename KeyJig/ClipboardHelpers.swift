import Cocoa
import os

private let log = Logger(subsystem: "com.cyzor.KeyJig", category: "Clipboard")

// MARK: - Clipboard SVG Detection

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
        log.error("error writing temp SVG: \(error.localizedDescription, privacy: .public)")
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
