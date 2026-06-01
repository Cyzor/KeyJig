import Cocoa
import os

private let log = Logger(subsystem: "com.cyzor.KeyJig", category: "KeynotePull")

// MARK: - Error type

enum KeynotePullError: LocalizedError {
    case keynoteNotRunning
    case noDocumentOpen
    case exportFailed(String)
    case pageMissing
    case fileWriteError(Error)

    var errorDescription: String? {
        switch self {
        case .keynoteNotRunning:
            return NSLocalizedString(
                "error.keynote.not_running",
                comment: "Error: Keynote is not running")
        case .noDocumentOpen:
            return NSLocalizedString(
                "error.keynote.no_document",
                comment: "Error: Keynote has no document open")
        case .exportFailed(let detail):
            return String(
                format: NSLocalizedString(
                    "error.keynote.export_failed",
                    comment: "Error: Keynote PDF export failed (with detail)"),
                detail)
        case .pageMissing:
            return NSLocalizedString(
                "error.keynote.page_missing",
                comment: "Error: the exported PDF has no page for the current slide")
        case .fileWriteError(let underlying):
            return underlying.localizedDescription
        }
    }
}

// MARK: - Public entry point

/// Pulls vector graphics from the current Keynote slide as a PDF.
///
/// `wantSelection` — when `true`, the probe runs to read the current
/// selection geometry and the result is cropped to the union of the selected
/// items' bounding boxes. When `false` (default), the current slide is always
/// freshly exported via the skipped-slide trick; `clipboardPDFData` is only
/// used as a last-resort fallback if that export fails (e.g. large files).
///
/// `clipboardPDFData` — caller should snapshot `NSPasteboard.general` on the
/// main thread before calling. When `wantSelection` is true it is used as the
/// crop source (avoiding a slow export); when `wantSelection` is false it is
/// held in reserve and only used if the export fails.
///
/// Calls completion on the main thread.
func pullFromKeynote(
    wantSelection: Bool = false,
    clipboardPDFData: Data? = nil,
    completion: @escaping (Result<URL, KeynotePullError>) -> Void
) {
    // Serial queue keeps NSAppleScript calls non-concurrent.
    let queue = DispatchQueue(label: "com.cyzor.KeyJig.keynotePull", qos: .userInitiated)
    queue.async {

        // 1. Verify Keynote is running.
        guard NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.iWork.Keynote").first != nil
        else {
            DispatchQueue.main.async { completion(.failure(.keynoteNotRunning)) }
            return
        }

        // 2. Probe: collect selection geometry. Skipped when `wantSelection` is
        //    false — for a full-slide pull the export script works from
        //    `current slide` directly with no geometry needed.
        //
        //    Batch property reads (position/width/height/rotation of the whole
        //    selection list at once) cut Apple Event round-trips from 4×N to 4,
        //    eliminating per-item flicker on large selections. A per-item
        //    fallback handles Keynote versions that reject list property access.
        let selectionBoxes: [SelectionBox]
        if wantSelection {
            let probeScript = """
                tell application "Keynote"
                    if not (exists front document) then error number -1728
                    tell front document
                        set targetSlide to current slide
                        set nSlides to count of slides
                        set slideIdx to 0
                        repeat with i from 1 to nSlides
                            if slide i is targetSlide then
                                set slideIdx to i
                                exit repeat
                            end if
                        end repeat
                        set sel to selection
                        set selCount to count of sel
                        set bboxLines to ""
                        if selCount > 0 then
                            try
                                set posList to position of sel
                                set widList to width of sel
                                set htList to height of sel
                                set rotList to {}
                                try
                                    set rotList to rotation of sel
                                on error
                                    repeat selCount times
                                        set rotList to rotList & {0}
                                    end repeat
                                end try
                                repeat with i from 1 to selCount
                                    set p to item i of posList
                                    set bboxLines to bboxLines & (item 1 of p) & "," & (item 2 of p) & "," & (item i of widList) & "," & (item i of htList) & "," & (item i of rotList) & linefeed
                                end repeat
                            on error
                                repeat with itm in sel
                                    try
                                        set p to position of itm
                                        set w to width of itm
                                        set h to height of itm
                                        set r to 0
                                        try
                                            set r to rotation of itm
                                        end try
                                        set bboxLines to bboxLines & (item 1 of p) & "," & (item 2 of p) & "," & w & "," & h & "," & r & linefeed
                                    end try
                                end repeat
                            end try
                        end if
                        return (slideIdx as string) & "|" & bboxLines
                    end tell
                end tell
                """
            var probeError: NSDictionary?
            let probeResult = NSAppleScript(source: probeScript)!
                .executeAndReturnError(&probeError)
            if let err = probeError {
                let code = err["NSAppleScriptErrorNumber"] as? Int ?? 0
                if code == -1728 {
                    DispatchQueue.main.async { completion(.failure(.noDocumentOpen)) }
                } else {
                    let detail = err["NSAppleScriptErrorMessage"] as? String ?? "AppleScript error \(code)"
                    log.error("probe failed: \(detail, privacy: .public)")
                    DispatchQueue.main.async { completion(.failure(.exportFailed(detail))) }
                }
                return
            }
            guard let probeString = probeResult.stringValue else {
                DispatchQueue.main.async { completion(.failure(.exportFailed("empty probe result"))) }
                return
            }
            let parts = probeString.components(separatedBy: "|")
            guard let slideIndex = Int(parts.first ?? ""), slideIndex > 0 else {
                DispatchQueue.main.async {
                    completion(.failure(.exportFailed("could not determine slide position")))
                }
                return
            }
            selectionBoxes = {
                guard parts.count > 1 else { return [] }
                return parts[1]
                    .split(whereSeparator: \.isNewline)
                    .compactMap { line in
                        let nums = line.split(separator: ",")
                            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                        guard nums.count == 5 else { return nil }
                        return SelectionBox(x: nums[0], y: nums[1], w: nums[2], h: nums[3], rotation: nums[4])
                    }
            }()
            log.info("slide index \(slideIndex, privacy: .public), \(selectionBoxes.count, privacy: .public) selected item(s)")
        } else {
            selectionBoxes = []
        }

        // 3a. Clipboard fast path (selection mode only): if the caller
        //     snapshotted a Keynote PDF, use it as the crop source directly.
        //     No export, no document modification. This is the only viable
        //     path for large or complex files that fail during export.
        //     For the default full-slide pull this block is skipped so the
        //     export always fetches a fresh copy of the current slide.
        if wantSelection, let data = clipboardPDFData {
            let srcURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("KeyJig-clipboard-\(UUID().uuidString).pdf")
            var srcWritten = false
            do {
                try data.write(to: srcURL)
                srcWritten = true
            } catch {
                log.info("clipboard PDF write failed, falling back to export: \(error.localizedDescription, privacy: .public)")
            }
            if srcWritten {
                log.info("clipboard PDF fast path (selection) — no export needed")
                let result = extractSlidePDF(
                    from: srcURL,
                    pageNumber: 1,
                    selectionBoxes: selectionBoxes,
                    padding: 8.0)
                try? FileManager.default.removeItem(at: srcURL)
                DispatchQueue.main.async { completion(result) }
                return
            }
        }

        // 3b. GUI scripting path (default full-slide pull only):
        //     Activate Keynote and send two Escape presses followed by ⌘C.
        //     First Escape exits text editing or deselects any selected object;
        //     second Escape moves focus to the navigator with the current slide
        //     selected. ⌘C then copies the whole slide (PDF + native data) to
        //     the clipboard — identical to the user clicking the thumbnail and
        //     pressing ⌘C. Falls through to the export path below if
        //     Accessibility permission is not granted or the script fails.
        if !wantSelection {
            let guiScript = """
                tell application "Keynote"
                    if not (exists front document) then error number -1728
                    activate
                end tell
                tell application "System Events"
                    tell process "Keynote"
                        set frontmost to true
                        key code 53
                        delay 0.05
                        key code 53
                        delay 0.15
                        keystroke "c" using {command down}
                    end tell
                end tell
                """
            // Snapshot change count before scripting so we can confirm ⌘C fired.
            let priorChangeCount: Int = DispatchQueue.main.sync {
                NSPasteboard.general.changeCount
            }
            var guiError: NSDictionary?
            NSAppleScript(source: guiScript)!.executeAndReturnError(&guiError)
            if guiError == nil {
                // Keynote needs a moment to finish writing the clipboard.
                Thread.sleep(forTimeInterval: 0.3)
                // Read on main thread; reject if the change count didn't move
                // (means ⌘C landed somewhere other than the slide navigator).
                let guiClipData: Data? = DispatchQueue.main.sync {
                    let pb = NSPasteboard.general
                    guard pb.changeCount != priorChangeCount else {
                        log.info("clipboard unchanged after GUI script — ⌘C did not fire on slide")
                        return nil
                    }
                    return ["com.adobe.pdf", "Apple PDF pasteboard type"]
                        .lazy
                        .compactMap { pb.data(forType: NSPasteboard.PasteboardType($0)) }
                        .first { !$0.isEmpty }
                }
                if let data = guiClipData {
                    let srcURL = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("KeyJig-clipboard-\(UUID().uuidString).pdf")
                    if (try? data.write(to: srcURL)) != nil {
                        log.info("GUI scripting path succeeded")
                        let result = extractSlidePDF(
                            from: srcURL,
                            pageNumber: 1,
                            selectionBoxes: [],
                            padding: 8.0)
                        try? FileManager.default.removeItem(at: srcURL)
                        DispatchQueue.main.async { completion(result) }
                        return
                    }
                }
                log.info("GUI scripting ran but clipboard had no PDF, falling through to export")
            } else {
                let detail = guiError!["NSAppleScriptErrorMessage"] as? String ?? "unknown"
                log.info("GUI scripting failed (\(detail, privacy: .public)), falling through to export")
            }
        }

        // 3c. Export only the current slide via the skipped-slide trick:
        //     mark all other slides as skipped, export, restore. The target
        //     slide is identified by object reference so sub-slides (whose
        //     display number can match a parent) are handled correctly.
        //     The exported PDF has exactly one page, so pageNumber is always 1.
        let exportURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("KeyJig-export-\(UUID().uuidString).pdf")
        let exportScript = """
            tell application "Keynote"
                tell front document
                    set savedSkipped to skipped of every slide
                    set nSlides to count of slides
                    set targetSlide to current slide
                    try
                        repeat with i from 1 to nSlides
                            if slide i is not targetSlide then
                                if not (item i of savedSkipped) then
                                    set skipped of slide i to true
                                end if
                            end if
                        end repeat
                        export to (POSIX file "\(exportURL.path)") as PDF with properties {skipped slides:false}
                    on error errMsg number errNum
                        repeat with i from 1 to nSlides
                            set skipped of slide i to (item i of savedSkipped)
                        end repeat
                        error errMsg number errNum
                    end try
                    repeat with i from 1 to nSlides
                        set skipped of slide i to (item i of savedSkipped)
                    end repeat
                end tell
            end tell
            """
        var exportError: NSDictionary?
        NSAppleScript(source: exportScript)!
            .executeAndReturnError(&exportError)
        if let err = exportError {
            let detail = err["NSAppleScriptErrorMessage"] as? String ?? "unknown"
            log.error("export failed: \(detail, privacy: .public)")
            // For the full-slide path, read the current clipboard fresh as a
            // last resort (covers large/complex files that Keynote can't export).
            // Reading fresh here rather than using a pre-snapshotted value avoids
            // showing stale data from a previous session.
            if !wantSelection {
                let fallbackData: Data? = DispatchQueue.main.sync {
                    let pb = NSPasteboard.general
                    return ["com.adobe.pdf", "Apple PDF pasteboard type"]
                        .lazy
                        .compactMap { pb.data(forType: NSPasteboard.PasteboardType($0)) }
                        .first { !$0.isEmpty }
                }
                if let data = fallbackData {
                    let srcURL = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("KeyJig-clipboard-\(UUID().uuidString).pdf")
                    if (try? data.write(to: srcURL)) != nil {
                        log.info("export failed; using current clipboard PDF as fallback")
                        let result = extractSlidePDF(from: srcURL, pageNumber: 1, selectionBoxes: [], padding: 8.0)
                        try? FileManager.default.removeItem(at: srcURL)
                        DispatchQueue.main.async { completion(result) }
                        return
                    }
                }
            }
            DispatchQueue.main.async { completion(.failure(.exportFailed(detail))) }
            return
        }

        // 4. Extract the slide page, optionally crop, write fresh PDF.
        //    The skipped-slide trick above means the exported PDF contains only
        //    one page (our target slide), so the page index is always 1.
        let result = extractSlidePDF(
            from: exportURL,
            pageNumber: 1,
            selectionBoxes: selectionBoxes,
            padding: 8.0)
        try? FileManager.default.removeItem(at: exportURL)
        DispatchQueue.main.async { completion(result) }
    }
}

// MARK: - Selection geometry

private struct SelectionBox {
    let x: Double       // top-left, Keynote coords (origin top-left)
    let y: Double
    let w: Double
    let h: Double
    let rotation: Double  // degrees

    /// Axis-aligned bounding box in Keynote coords, expanded for rotation.
    var aabb: CGRect {
        let theta = rotation * .pi / 180.0
        let absCos = abs(cos(theta))
        let absSin = abs(sin(theta))
        let aabbW = w * absCos + h * absSin
        let aabbH = w * absSin + h * absCos
        let cx = x + w / 2
        let cy = y + h / 2
        return CGRect(x: cx - aabbW / 2, y: cy - aabbH / 2, width: aabbW, height: aabbH)
    }
}

// MARK: - External tool probes

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

// MARK: - PDF extraction

private func extractSlidePDF(
    from exportURL: URL,
    pageNumber: Int,
    selectionBoxes: [SelectionBox],
    padding: CGFloat
) -> Result<URL, KeynotePullError> {
    guard let sourceDoc = CGPDFDocument(exportURL as CFURL) else {
        return .failure(.exportFailed("could not load exported PDF"))
    }
    // CGPDFDocument.page(at:) is 1-indexed.
    guard pageNumber >= 1, pageNumber <= sourceDoc.numberOfPages,
          let cgPage = sourceDoc.page(at: pageNumber)
    else {
        return .failure(.pageMissing)
    }

    let pageRect = cgPage.getBoxRect(.mediaBox)

    // Determine crop rect in PDF coords (origin bottom-left).
    let cropRect: CGRect
    if selectionBoxes.isEmpty {
        cropRect = pageRect
    } else {
        let union = selectionBoxes.dropFirst().reduce(selectionBoxes[0].aabb) { $0.union($1.aabb) }
        // Flip Y from Keynote (top-left origin) to PDF (bottom-left origin).
        let pdfY = pageRect.height - (union.minY + union.height)
        var r = CGRect(x: union.minX, y: pdfY, width: union.width, height: union.height)
        r = r.insetBy(dx: -padding, dy: -padding)
        cropRect = r.intersection(pageRect)
    }

    // Prefer external tools that genuinely rewrite the content stream so no
    // drawing commands survive outside the crop area. CGPDFContext embeds the
    // source page as a Form XObject and clips it in the outer stream — correct
    // for display but the raw data is still present, which InDesign exposes.
    //
    // Strategy:
    //   1. Ghostscript pdfwrite — crops directly from the Keynote export in one
    //      pass; the PostScript engine only outputs what falls within the clip.
    //   2. mutool draw — re-renders our CGPDFContext intermediate through
    //      MuPDF's pdfwrite device, stripping the hidden Form XObject content.
    //   3. CGPDFContext alone — display-correct but content not removed.

    if !selectionBoxes.isEmpty, let gs = ghostscriptURL() {
        let outURL = makeTempKeynotePDFURL()
        if cropWithGhostscript(gs: gs, input: exportURL, cropRect: cropRect, output: outURL) {
            log.info("crop via gs succeeded")
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outURL.path)
            return .success(outURL)
        }
        log.info("gs crop failed, trying next path")
    }

    // Build the CGPDFContext intermediate — used as the final result when no
    // external tool is available, or as mutool's input when gs is absent.
    let cgURL = makeTempKeynotePDFURL()
    var outMediaBox = CGRect(origin: .zero, size: cropRect.size)
    guard let pdfCtx = CGContext(cgURL as CFURL, mediaBox: &outMediaBox, nil) else {
        return .failure(.exportFailed("could not create PDF context"))
    }
    pdfCtx.beginPDFPage(nil)
    pdfCtx.clip(to: outMediaBox)
    pdfCtx.translateBy(x: -cropRect.minX, y: -cropRect.minY)
    pdfCtx.drawPDFPage(cgPage)
    pdfCtx.endPDFPage()
    pdfCtx.closePDF()

    guard FileManager.default.fileExists(atPath: cgURL.path) else {
        return .failure(.exportFailed("PDF context failed to write output"))
    }

    if !selectionBoxes.isEmpty, let mt = mutoolURL() {
        let outURL = makeTempKeynotePDFURL()
        if reprocessWithMutool(mutool: mt, input: cgURL, output: outURL) {
            log.info("crop via mutool succeeded")
            try? FileManager.default.removeItem(at: cgURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outURL.path)
            return .success(outURL)
        }
        log.info("mutool reprocess failed, using CGPDFContext output")
        try? FileManager.default.removeItem(at: outURL)
    }

    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cgURL.path)
    return .success(cgURL)
}

// MARK: - Destructive crop helpers

/// Ghostscript crops directly from the source PDF: the pdfwrite device re-renders
/// through its PostScript engine, so only content within the crop area survives.
private func cropWithGhostscript(gs: URL, input: URL, cropRect: CGRect, output: URL) -> Bool {
    let w = String(format: "%.4f", cropRect.width)
    let h = String(format: "%.4f", cropRect.height)
    let tx = String(format: "%.4f", -cropRect.minX)
    let ty = String(format: "%.4f", -cropRect.minY)

    let task = Process()
    task.executableURL = gs
    task.arguments = [
        "-sDEVICE=pdfwrite",
        "-dBATCH", "-dNOPAUSE", "-dSAFER", "-dQUIET",
        "-dDEVICEWIDTHPOINTS=\(w)",
        "-dDEVICEHEIGHTPOINTS=\(h)",
        "-dFIXEDMEDIA",
        "-dPDFSETTINGS=/prepress",
        "-sOutputFile=\(output.path)",
        "-c", "<</BeginPage{pop \(tx) \(ty) translate}bind>>setpagedevice",
        "-f", input.path,
    ]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    do {
        try task.run(); task.waitUntilExit()
    } catch {
        log.error("gs launch failed: \(error.localizedDescription, privacy: .public)")
        return false
    }
    return task.terminationStatus == 0 && FileManager.default.fileExists(atPath: output.path)
}

/// mutool draw re-renders the CGPDFContext intermediate through MuPDF's pdfwrite
/// device. The Form XObject introduced by CGPDFContext is resolved during
/// rendering, so drawing commands outside the clip are not emitted.
private func reprocessWithMutool(mutool: URL, input: URL, output: URL) -> Bool {
    let task = Process()
    task.executableURL = mutool
    task.arguments = ["draw", "-o", output.path, input.path]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    do {
        try task.run(); task.waitUntilExit()
    } catch {
        log.error("mutool launch failed: \(error.localizedDescription, privacy: .public)")
        return false
    }
    return task.terminationStatus == 0 && FileManager.default.fileExists(atPath: output.path)
}

// MARK: - Temp file naming

/// Generates a unique temp-file URL with a human-readable name of the form
/// "KeyJig-Slide-YYYY-MM-DD-xxxxxxxx.pdf".
func makeTempKeynotePDFURL() -> URL {
    let date: String = {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }()
    let uuid = UUID().uuidString.prefix(8)
    let name = "KeyJig-Slide-\(date)-\(uuid).pdf"
    return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
}

// MARK: - Clipboard helper

/// Writes the PDF data and a file URL to the general pasteboard.
/// Returns true on success.
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
