import Cocoa
import os

private let log = Logger(subsystem: "com.cyzor.KeyJig", category: "KeynotePull")

// MARK: - Error type

enum KeynotePullError: LocalizedError {
    case keynoteNotRunning
    case noDocumentOpen
    case exportFailed(String)
    case pageMissing
    case cancelled

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
        case .cancelled:
            return NSLocalizedString(
                "error.keynote.cancelled",
                comment: "Error: the Keynote pull operation was cancelled by the user")
        }
    }
}

// MARK: - Cancellation token

/// A thread-safe token that signals cancellation across async pull steps.
/// Create one per pull invocation and store it on AppState so the UI can cancel.
final class PullCancellationToken {
    private let lock = NSLock()
    private var _cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _cancelled
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        _cancelled = true
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
    cancellationToken: PullCancellationToken? = nil,
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

        // Capture the frontmost app so we can restore it after Keynote activates.
        let prevFrontApp: NSRunningApplication? = DispatchQueue.main.sync {
            NSWorkspace.shared.frontmostApplication
        }

        // Unhide Keynote if it is hidden — a hidden app silently ignores
        // AppleScript export calls, causing the pull to stall indefinitely.
        // `unhide()` makes the app visible without stealing focus.
        if let keynoteApp = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.iWork.Keynote").first,
            keynoteApp.isHidden
        {
            log.info("Keynote is hidden; unhiding before export")
            keynoteApp.unhide()
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Source info used to build a descriptive output filename.
        // Populated by the probe (selection pull) or the name-fetch block below (full-slide pull).
        var pdfDocName: String? = nil
        var pdfSlideIndex: Int? = nil

        // 2. Probe: collect selection geometry. Skipped when `wantSelection` is
        //    false — for a full-slide pull the export script works from
        //    `current slide` directly with no geometry needed.
        //
        //    Batch property reads (position/width/height/rotation of the whole
        //    selection list at once) cut Apple Event round-trips from 4×N to 4,
        //    eliminating per-item flicker on large selections. A per-item
        //    fallback handles Keynote versions that reject list property access.
        var probeSlideIndex: Int = 0
        let selectionBoxes: [SelectionBox]
        if wantSelection {
            let probeScript = """
                tell application "Keynote"
                    with timeout of 30 seconds
                    if not (exists front document) then error number -1728
                    set docCount to count of documents
                    tell front document
                        set docName to name
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
                        return (slideIdx as string) & "|" & bboxLines & "|" & docName & "|" & (docCount as string)
                    end tell
                    end timeout
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
            probeSlideIndex = slideIndex
            let probeDocName = parts.count > 2 ? parts[2] : "?"
            let probeDocCount = parts.count > 3 ? parts[3] : "?"
            log.info("probe: front document='\(probeDocName, privacy: .public)' (of \(probeDocCount, privacy: .public) open), slide index \(slideIndex, privacy: .public), \(selectionBoxes.count, privacy: .public) selected item(s)")
            pdfDocName = probeDocName
            pdfSlideIndex = slideIndex
        } else {
            selectionBoxes = []
        }

        if cancellationToken?.isCancelled == true {
            DispatchQueue.main.async { completion(.failure(.cancelled)) }
            return
        }

        // Full-slide pull: the probe above is skipped, so fetch doc name + slide
        // index now for the output filename. One cheap AppleScript call; the
        // slide-index loop is O(n) but runs before the heavier export work.
        if !wantSelection {
            let nameScript = """
                tell application "Keynote"
                    with timeout of 30 seconds
                    if not (exists front document) then error number -1728
                    tell front document
                        set docName to name
                        set tgt to current slide
                        set n to count of slides
                        set idx to 0
                        repeat with i from 1 to n
                            if slide i is tgt then set idx to i
                        end repeat
                        return docName & "|" & (idx as string)
                    end tell
                    end timeout
                end tell
                """
            var nameErr: NSDictionary?
            let nameRes = NSAppleScript(source: nameScript)!.executeAndReturnError(&nameErr)
            if let err = nameErr {
                let code = (err["NSAppleScriptErrorNumber"] as? Int) ?? 0
                if code == -1728 {
                    DispatchQueue.main.async { completion(.failure(.noDocumentOpen)) }
                    return
                }
                // Other errors (e.g., Keynote busy): log and continue without doc name.
                let msg = err["NSAppleScriptErrorMessage"] as? String ?? "error \(code)"
                log.info("name fetch failed (\(msg, privacy: .public)); proceeding without doc name")
            } else if let s = nameRes.stringValue, !s.isEmpty {
                let f = s.components(separatedBy: "|")
                pdfDocName = f.first.flatMap { $0.isEmpty ? nil : $0 }
                pdfSlideIndex = f.count > 1 ? Int(f[1]) : nil
            }

            if cancellationToken?.isCancelled == true {
                DispatchQueue.main.async { completion(.failure(.cancelled)) }
                return
            }
        }

        // 3a-paste. Vector selection-only via a throwaway document (preferred for
        //     a selection pull). Requires the user to have copied their selection
        //     (⌘C); pastes the native objects into a scratch doc, exports vector,
        //     crops to content. Interloper-free even for non-contiguous selections;
        //     never touches the user's deck/selection/clipboard. Falls through when
        //     the clipboard doesn't match the live selection or paste/export fails.
        if wantSelection, !selectionBoxes.isEmpty,
           let kpid = NSRunningApplication
               .runningApplications(withBundleIdentifier: "com.apple.iWork.Keynote")
               .first?.processIdentifier,
           let url = extractSelectionViaPaste(selectionBoxes: selectionBoxes, keynotePID: kpid,
               docName: pdfDocName, slideIndex: pdfSlideIndex) {
            // The scratch-doc round-trip drops the user's canvas selection; restore it.
            restoreKeynoteSelection(slideIndex: probeSlideIndex, selectionBoxes: selectionBoxes)
            DispatchQueue.main.async {
                prevFrontApp?.activateFrontmost()
                completion(.success(url))
            }
            return
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
                    padding: 40.0,
                    docName: pdfDocName,
                    slideIndex: pdfSlideIndex)
                try? FileManager.default.removeItem(at: srcURL)
                DispatchQueue.main.async {
                    prevFrontApp?.activateFrontmost()
                    completion(result)
                }
                return
            }
        }

        if cancellationToken?.isCancelled == true {
            DispatchQueue.main.async { completion(.failure(.cancelled)) }
            return
        }

        // 3b. Export the current slide as PDF.
        //
        //     Selection pull (wantSelection=true): export the entire document
        //     and extract page probeSlideIndex. No Keynote state is modified so
        //     the user's selection is naturally preserved — no restore needed.
        //     Slower for large decks, but the selection pull is already a
        //     deliberate, targeted operation and the skipped-slide trick is what
        //     was silently clearing the canvas selection.
        //
        //     Full-slide pull (wantSelection=false): use the skipped-slide trick
        //     (mark all other slides skipped, export, restore). Fast for large
        //     decks. Skip/restore use batch list-property assignment to avoid
        //     O(n) Apple Events; a per-item fallback handles older Keynote.
        let exportURL = makeTempKeynotePDFURL()
        let exportScript: String
        if wantSelection {
            exportScript = """
                tell application "Keynote"
                    with timeout of 90 seconds
                    tell front document
                        export to (POSIX file "\(exportURL.path)") as PDF
                    end tell
                    end timeout
                end tell
                """
        } else {
            exportScript = """
                tell application "Keynote"
                    with timeout of 90 seconds
                    tell front document
                        set savedSkipped to skipped of every slide
                        set nSlides to count of slides
                        set targetSlide to current slide
                        try
                            set skipped of every slide to true
                            set skipped of targetSlide to false
                            export to (POSIX file "\(exportURL.path)") as PDF with properties {skipped slides:false}
                            my restoreSkips(savedSkipped, nSlides)
                        on error errMsg number errNum
                            my restoreSkips(savedSkipped, nSlides)
                            error errMsg number errNum
                        end try
                    end tell
                    end timeout
                end tell

                on restoreSkips(savedSkipped, nSlides)
                    tell front document of application "Keynote"
                        with timeout of 30 seconds
                        try
                            set skipped of every slide to savedSkipped
                        on error
                            repeat with i from 1 to nSlides
                                set skipped of slide i to (item i of savedSkipped)
                            end repeat
                        end try
                        end timeout
                    end tell
                end restoreSkips
                """
        }
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
                        let result = extractSlidePDF(from: srcURL, pageNumber: 1, selectionBoxes: [],
                            padding: 40.0, docName: pdfDocName, slideIndex: pdfSlideIndex)
                        try? FileManager.default.removeItem(at: srcURL)
                        DispatchQueue.main.async {
                            prevFrontApp?.activateFrontmost()
                            completion(result)
                        }
                        return
                    }
                }
            }
            DispatchQueue.main.async { completion(.failure(.exportFailed(detail))) }
            return
        }

        // 4. Extract the slide page, optionally crop, write fresh PDF.
        //    The skipped-slide trick produces a 1-page PDF (page index always 1).
        //    The full-document export (selection path) produces one page per slide,
        //    so we extract by probeSlideIndex.
        let result = extractSlidePDF(
            from: exportURL,
            pageNumber: wantSelection ? probeSlideIndex : 1,
            selectionBoxes: selectionBoxes,
            padding: 40.0,
            docName: pdfDocName,
            slideIndex: pdfSlideIndex)
        try? FileManager.default.removeItem(at: exportURL)

        // 5. Restore the user's selection (selection pull only).
        if wantSelection {
            restoreKeynoteSelection(slideIndex: probeSlideIndex, selectionBoxes: selectionBoxes)
        }

        DispatchQueue.main.async {
            prevFrontApp?.activateFrontmost()
            completion(result)
        }
    }
}

/// Re-asserts the user's canvas selection by position-matching.
///
/// Saved specifier objects go stale after any export or scratch-doc round-trip,
/// so this builds fresh `iWork item` references at restore time by iterating the
/// slide's items and matching by position — the references in `toSelect` are live
/// at the exact moment `set selection` is called, the only pattern that works.
private func restoreKeynoteSelection(slideIndex: Int, selectionBoxes: [SelectionBox]) {
    guard slideIndex > 0, !selectionBoxes.isEmpty else { return }
    let posChecks = selectionBoxes.map { box in
        let x = Int(box.x.rounded())
        let y = Int(box.y.rounded())
        return "((item 1 of p) = \(x) and (item 2 of p) = \(y))"
    }.joined(separator: " or ")
    let restoreScript = """
        tell application "Keynote"
            activate
            tell front document
                set current slide to slide \(slideIndex)
                set toSelect to {}
                repeat with sh in iWork items of slide \(slideIndex)
                    set p to position of sh
                    if \(posChecks) then
                        set end of toSelect to sh
                    end if
                end repeat
                if toSelect is not {} then set selection to toSelect
            end tell
        end tell
        """
    var restoreError: NSDictionary?
    NSAppleScript(source: restoreScript)!.executeAndReturnError(&restoreError)
    if let err = restoreError {
        log.info("selection restore failed: \(err["NSAppleScriptErrorMessage"] as? String ?? "unknown", privacy: .public)")
    } else {
        log.info("selection restored via position matching: \(selectionBoxes.count, privacy: .public) item(s)")
    }
}

// MARK: - Vector selection-only extraction via a throwaway document
//
// The user copies their Keynote selection (⌘C) — the *native* object data on the
// clipboard, which Keynote-to-Keynote paste reconstructs as real vector objects
// (unlike the rasterized PDF flavor other apps see). KeyJig makes a scratch doc
// sized to the source slide, blanks its theme placeholders, AX-pastes the
// selection (AXPress, immune to keyboard focus / Dvorak / German menus), exports
// it as vector, crops to the pasted content, then discards the scratch doc.
//
// Because the scratch slide holds ONLY the selected objects, the result is
// interloper-free even for a non-contiguous selection — the limitation of the
// bounding-box crop. The user's deck, slide, selection, and clipboard are never
// touched, so no selection restore is needed.
//
// Guard against a clipboard that doesn't match the live selection (user didn't
// copy, or copied something else): the pasted item count and bounding-box extent
// must match the probe's selection. On any mismatch — or a paste/export failure —
// returns nil so the caller falls through to the export+crop tier (which reads
// live geometry and is always current, just bounding-box-limited). The scratch
// doc is always closed unsaved, even on the failure path, so Keynote never pops a
// save dialog that would hang subsequent Apple Events.
private func extractSelectionViaPaste(
    selectionBoxes: [SelectionBox],
    keynotePID: pid_t,
    docName: String? = nil,
    slideIndex: Int? = nil
) -> URL? {
    guard !selectionBoxes.isEmpty else { return nil }
    let selN = selectionBoxes.count
    let selExtent = selectionBoxes.dropFirst().reduce(selectionBoxes[0].aabb) { $0.union($1.aabb) }

    // The user must have copied the selection (⌘C) — the native object data on the
    // clipboard is what we paste. Fully-automatic copy is unreachable: AppleScript's
    // `selection` model holds all N items, but after KeyJig takes focus the canvas
    // only hands Copy what is live (often 1), and re-asserting the selection via
    // AppleScript doesn't stick without human key events on the canvas (see
    // CLAUDE.md). So we rely on the human's ⌘C and validate it matched below.

    // Source slide size, so pasted objects keep their proportions and don't clip.
    let sizeScript = """
        tell application "Keynote"
            if not (exists front document) then error number -1728
            tell front document to return (width as string) & "," & (height as string)
        end tell
        """
    var eSize: NSDictionary?
    let rSize = NSAppleScript(source: sizeScript)!.executeAndReturnError(&eSize)
    guard eSize == nil, let szStr = rSize.stringValue else { return nil }
    let szs = szStr.split(separator: ",").compactMap { Int(Double($0) ?? 0) }
    let w = szs.count == 2 ? szs[0] : 1024
    let h = szs.count == 2 ? szs[1] : 768

    // Scratch doc → match size → blank placeholders → activate.
    // Returns the new document's name so finishScript can address it by name
    // rather than relying on `front document`, which may shift if the paste
    // action causes another window to come forward.
    let setupScript = """
        tell application "Keynote"
            set d to make new document
            tell d
                set its width to \(w)
                set its height to \(h)
                try
                    delete every iWork item of slide 1
                end try
            end tell
            activate
            return name of d
        end tell
        """
    var eSetup: NSDictionary?
    let rSetup = NSAppleScript(source: setupScript)!.executeAndReturnError(&eSetup)
    if let e = eSetup {
        log.info("paste tier: scratch-doc setup failed: \(e["NSAppleScriptErrorMessage"] as? String ?? "?", privacy: .public)")
        return nil
    }
    guard let scratchName = rSetup.stringValue, !scratchName.isEmpty else {
        log.info("paste tier: could not read scratch doc name — aborting")
        return nil
    }
    log.info("paste tier: scratch doc is '\(scratchName, privacy: .public)'")
    Thread.sleep(forTimeInterval: 0.3)

    // Always close the scratch doc on any exit path once we have its name.
    // A dedicated close script (rather than embedding it inside finishScript)
    // ensures the close runs even when finishScript itself returns an error.
    // The brief sleep gives Keynote time to finish any post-export bookkeeping
    // before the close command arrives, avoiding silent close failures.
    defer {
        Thread.sleep(forTimeInterval: 0.15)
        let closeScript = """
            tell application "Keynote"
                try
                    close document "\(scratchName)" saving no
                end try
            end tell
            """
        var eClose: NSDictionary?
        NSAppleScript(source: closeScript)!.executeAndReturnError(&eClose)
        if let e = eClose {
            log.error("paste tier: scratch doc '\(scratchName, privacy: .public)' close error — \(e["NSAppleScriptErrorMessage"] as? String ?? "?", privacy: .public)")
        }
    }

    // AX-paste the user's copied selection into the scratch doc.
    _ = pressMenuItemWithCmdChar("v", appPID: keynotePID)
    Thread.sleep(forTimeInterval: 0.4)

    // Read pasted count + geometry, export (failure-proof). Close happens in defer.
    // Batch-read position/size/rotation in one AE round-trip per property so
    // AppleScript never needs to touch individual items — which causes Keynote
    // to briefly highlight each one, producing the "deselects one by one" effect.
    let exportURL = makeTempKeynotePDFURL()
    // Address the scratch doc by name so that even if the paste action caused
    // another window to come forward, we never read from or close the wrong doc.
    let finishScript = """
        tell application "Keynote"
            set m to 0
            set okExport to false
            set geo to ""
            set exportErr to ""
            try
                tell document "\(scratchName)"
                    set itms to iWork items of slide 1
                    set m to count of itms
                    -- Geometry reading is best-effort; charts can't be queried
                    -- via the batch iWork-item specifier and throw here. Wrap in
                    -- a bare try so failure is silent and export still proceeds.
                    if m > 0 then
                        try
                            set posList to position of itms
                            set widList to width of itms
                            set htList to height of itms
                            set rotList to {}
                            try
                                set rotList to rotation of itms
                            on error
                                repeat m times
                                    set rotList to rotList & {0}
                                end repeat
                            end try
                            repeat with i from 1 to m
                                set p to item i of posList
                                set geo to geo & (item 1 of p) & "," & (item 2 of p) & "," & (item i of widList) & "," & (item i of htList) & "," & (item i of rotList) & ";"
                            end repeat
                        end try
                    end if
                    export to (POSIX file "\(exportURL.path)") as PDF
                    set okExport to true
                end tell
            on error errMsg
                set exportErr to errMsg
            end try
            return (m as string) & "|" & (okExport as string) & "|" & geo & "|" & exportErr
        end tell
        """
    var eFinish: NSDictionary?
    let rFinish = NSAppleScript(source: finishScript)!.executeAndReturnError(&eFinish)
    guard eFinish == nil, let out = rFinish.stringValue else {
        try? FileManager.default.removeItem(at: exportURL)
        return nil
    }
    let parts = out.components(separatedBy: "|")
    let m = Int(parts.first ?? "") ?? 0
    let okExport = parts.count > 1 && parts[1] == "true"
    let scratchBoxes: [SelectionBox] = (parts.count > 2 ? parts[2] : "")
        .split(separator: ";")
        .compactMap { line in
            let n = line.split(separator: ",").compactMap { Double($0) }
            guard n.count == 5 else { return nil }
            return SelectionBox(x: n[0], y: n[1], w: n[2], h: n[3], rotation: n[4])
        }
    if !okExport, parts.count > 3, !parts[3].isEmpty {
        log.info("paste tier: scratch-doc export error: \(parts[3], privacy: .public)")
    }

    // Validate the clipboard actually held the live selection.
    // scratchBoxes may be empty for charts (geometry batch-read not supported);
    // count match + successful export is sufficient validation in that case.
    guard okExport, m == selN else {
        log.info("paste tier: clipboard didn't match selection (pasted \(m, privacy: .public) vs \(selN, privacy: .public), export=\(okExport, privacy: .public)) — falling back to export+crop")
        try? FileManager.default.removeItem(at: exportURL)
        return nil
    }
    if !scratchBoxes.isEmpty {
        let scratchExtent = scratchBoxes.dropFirst().reduce(scratchBoxes[0].aabb) { $0.union($1.aabb) }
        let tol: CGFloat = 6
        guard abs(scratchExtent.width - selExtent.width) < tol,
              abs(scratchExtent.height - selExtent.height) < tol else {
            log.info("paste tier: extent mismatch (\(scratchExtent.width, privacy: .public)x\(scratchExtent.height, privacy: .public) vs \(selExtent.width, privacy: .public)x\(selExtent.height, privacy: .public)) — stale clipboard, falling back")
            try? FileManager.default.removeItem(at: exportURL)
            return nil
        }
    }

    // Crop the scratch export to the pasted content (read fresh from the scratch
    // doc — paste may offset positions). Only selected objects exist here, so the
    // bounding-box crop is interloper-free.
    // useContentBounds: scratch doc contains only selected objects, so the
    // rendered ink bbox is the exact right crop — captures chart labels and
    // leader lines that live outside the scripted geometry bounds.
    let result = extractSlidePDF(from: exportURL, pageNumber: 1, selectionBoxes: scratchBoxes,
        padding: 40.0, useContentBounds: true, docName: docName, slideIndex: slideIndex)
    try? FileManager.default.removeItem(at: exportURL)
    switch result {
    case .success(let url):
        log.info("paste tier: ✅ vector selection-only — \(m, privacy: .public) item(s) via scratch doc")
        return url
    case .failure(let err):
        log.info("paste tier: crop failed (\(err.localizedDescription, privacy: .public)) — falling back")
        return nil
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

// MARK: - PDF extraction

/// Renders one PDF page at reduced resolution and returns the tight bounding
/// box of all non-white ink, in PDF coordinates (origin bottom-left).
/// Passing the result to extractSlidePDF captures chart labels, leader lines,
/// and any other content that overflows the scripted object geometry.
/// Returns nil if rendering fails or the page has no non-white content.
private func contentBoundsByRendering(cgPage: CGPDFPage, pageRect: CGRect) -> CGRect? {
    guard pageRect.width > 0, pageRect.height > 0 else { return nil }
    // 1024px on the long edge: 1pt≈1px for standard Keynote slides so thin
    // leader lines (often 1pt) are reliably captured without subpixel dropout.
    let scale = min(1.0, 1024.0 / max(pageRect.width, pageRect.height))
    let w  = max(1, Int((pageRect.width  * scale).rounded()))
    let h  = max(1, Int((pageRect.height * scale).rounded()))
    let bpr = w * 4
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: h * bpr)
    defer { buf.deallocate() }
    memset(buf, 0xFF, h * bpr)   // white canvas

    guard let ctx = CGContext(data: buf, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: bpr,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }

    ctx.scaleBy(x: scale, y: scale)
    ctx.drawPDFPage(cgPage)

    // macOS CGContext bitmaps store row 0 at the visual top (high PDF y).
    // `by` = min row = topmost ink = highest PDF y (near page top).
    // `ty` = max row = bottommost ink = lowest PDF y (near page bottom).
    // PDF y of the bottom edge of content = (h - 1 - ty) / scale.
    var lx = w, rx = -1, by = h, ty = -1
    for row in 0..<h {
        let rowBase = buf + row * bpr
        for col in 0..<w {
            let p = rowBase + col * 4
            if p[0] < 250 || p[1] < 250 || p[2] < 250 {
                if col < lx { lx = col }
                if col > rx { rx = col }
                if row < by { by = row }
                if row > ty { ty = row }
            }
        }
    }
    guard rx >= 0 else { return nil }

    return CGRect(
        x:      CGFloat(lx)          / scale,
        y:      CGFloat(h - 1 - ty)  / scale,   // row ty → PDF y near bottom
        width:  CGFloat(rx - lx + 1) / scale,
        height: CGFloat(ty - by + 1) / scale
    )
}

private func extractSlidePDF(
    from exportURL: URL,
    pageNumber: Int,
    selectionBoxes: [SelectionBox],
    padding: CGFloat,
    useContentBounds: Bool = false,
    docName: String? = nil,
    slideIndex: Int? = nil
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
    if useContentBounds,
       let cb = contentBoundsByRendering(cgPage: cgPage, pageRect: pageRect) {
        // Scratch-doc path: the PDF contains exactly the selected objects.
        // Use the actual ink bounding box so chart data labels, leader lines,
        // and anything else that overflows the scripted geometry is included.
        // 4 pt expansion absorbs anti-aliasing at the outermost pixel edge.
        let r = cb.insetBy(dx: -4.0, dy: -4.0)
        cropRect = r.intersection(pageRect)
        log.info("content-bounds crop: \(cropRect.width, privacy: .public)×\(cropRect.height, privacy: .public) (page \(pageRect.width, privacy: .public)×\(pageRect.height, privacy: .public))")
    } else if !selectionBoxes.isEmpty {
        // Geometry-based fallback: crop to the union of reported object bounds
        // plus padding. Keynote's scripted geometry underreports chart overflow,
        // but this is the best available without PDF content information.
        let union = selectionBoxes.dropFirst().reduce(selectionBoxes[0].aabb) { $0.union($1.aabb) }
        // Flip Y from Keynote (top-left origin) to PDF (bottom-left origin).
        let pdfY = pageRect.height - (union.minY + union.height)
        var r = CGRect(x: union.minX, y: pdfY, width: union.width, height: union.height)
        r = r.insetBy(dx: -padding, dy: -padding)
        cropRect = r.intersection(pageRect)
    } else {
        cropRect = pageRect
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
        let outURL = docName.map { makeDescriptivePDFURL(docName: $0, slideIndex: slideIndex) }
            ?? makeTempKeynotePDFURL()
        if cropWithGhostscript(gs: gs, input: exportURL, cropRect: cropRect, output: outURL) {
            log.info("crop via gs succeeded")
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outURL.path)
            return .success(outURL)
        }
        log.info("gs crop failed, trying next path")
    }

    // Build the CGPDFContext intermediate — used as the final result when no
    // external tool is available, or as mutool's input when gs is absent.
    // Always UUID-based: both the GS and mutool success paths use a separate
    // descriptive URL, and giving cgURL the same descriptive name would make
    // cgURL == outURL, causing mutool to read and write the same file and the
    // subsequent removeItem(at: cgURL) to delete the result.
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
        let outURL = docName.map { makeDescriptivePDFURL(docName: $0, slideIndex: slideIndex) }
            ?? makeTempKeynotePDFURL()
        if reprocessWithMutool(mutool: mt, input: cgURL, output: outURL) {
            log.info("crop via mutool succeeded")
            try? FileManager.default.removeItem(at: cgURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outURL.path)
            return .success(outURL)
        }
        log.info("mutool reprocess failed, using CGPDFContext output")
        try? FileManager.default.removeItem(at: outURL)
    }

    // cgURL is the final output (no external tools available). Rename it to the
    // descriptive form now that we know it will be the result the user sees.
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cgURL.path)
    if let doc = docName {
        let finalURL = makeDescriptivePDFURL(docName: doc, slideIndex: slideIndex)
        if (try? FileManager.default.moveItem(at: cgURL, to: finalURL)) != nil {
            return .success(finalURL)
        }
    }
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

/// Generates a unique temp-file URL for intermediate processing files.
/// Uses a UUID suffix so concurrent pulls never collide.
/// Form: "KeyJig-Slide-YYYY-MM-DD-xxxxxxxx.pdf"
func makeTempKeynotePDFURL() -> URL {
    let date = isoDateString()
    let uuid = UUID().uuidString.prefix(8)
    let name = "KeyJig-Slide-\(date)-\(uuid).pdf"
    return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
}

/// Generates a descriptive URL for the PDF the user will actually see.
/// Form: "Keynote-{sanitized-doc-name}-{slide}-YYYY-MM-DD.pdf"
/// If slideIndex is nil (e.g. full-slide pull without probe), omits the slide component.
private func makeDescriptivePDFURL(docName: String, slideIndex: Int?) -> URL {
    let date = isoDateString()
    let safe = sanitizedDocName(docName, maxLength: 20)
    let slide = slideIndex.map { "-\($0)" } ?? ""
    let name = "Keynote-\(safe)\(slide)-\(date).pdf"
    return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
}

private func isoDateString() -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

/// Sanitizes a Keynote document name for use in a filename.
/// Replaces underscores, spaces, and dots with hyphens; strips non-alphanumeric chars;
/// collapses consecutive hyphens; truncates to maxLength at a hyphen boundary.
private func sanitizedDocName(_ name: String, maxLength: Int) -> String {
    // Strip the .key extension if it somehow arrived
    var s = name.hasSuffix(".key") ? String(name.dropLast(4)) : name
    // Underscores, spaces, dots → hyphens
    s = s.replacingOccurrences(of: "_", with: "-")
    s = s.replacingOccurrences(of: " ", with: "-")
    s = s.replacingOccurrences(of: ".", with: "-")
    // Keep only ASCII alphanumeric and hyphens (safe for all filesystems)
    s = s.unicodeScalars.filter {
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).contains($0)
    }.map { String($0) }.joined()
    // Collapse runs of hyphens
    while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
    s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    // Truncate at a hyphen boundary so we don't cut a word mid-stream
    if s.count > maxLength {
        let prefix = String(s.prefix(maxLength))
        s = prefix.lastIndex(of: "-").map { String(prefix[..<$0]) } ?? prefix
    }
    return s.isEmpty ? "Keynote" : s
}

// MARK: - Helpers

private extension NSRunningApplication {
    /// Activates the app, restoring it as the frontmost application.
    ///
    /// When re-activating our own process (the common case — user triggered a
    /// pull from KeyJig's menu or a button), use `NSApp.activate(ignoringOtherApps:
    /// true)`, which is exempt from macOS 14's focus-stealing prevention and works
    /// reliably from a background-queue completion callback. Activating a *different*
    /// app (uncommon) uses the weaker API so we don't steal focus from an app the
    /// user deliberately moved to while the pull was running.
    func activateFrontmost() {
        if bundleIdentifier == Bundle.main.bundleIdentifier {
            NSApp.activate(ignoringOtherApps: true)
        } else if #available(macOS 14.0, *) {
            activate()
        } else {
            activate(options: .activateIgnoringOtherApps)
        }
    }
}

// MARK: - Pull trigger actions

/// Shared action: convert the current Keynote slide to a vector PDF.
/// Called by both the button in ContentView and the File menu in AppDelegate.
func triggerKeynoteSlide(appState: AppState, setStatus: @escaping (String) -> Void) {
    guard appState.keynotePullStatus != .pulling else { return }
    let token = PullCancellationToken()
    appState.activePullToken = token
    appState.keynotePullStatus = .pulling
    setStatus(NSLocalizedString("status.keynote.pulling",
        comment: "Status: PDF export from Keynote in progress"))
    appState.previewPDFURL = nil
    pullFromKeynote(wantSelection: false, clipboardPDFData: nil, cancellationToken: token) { result in
        appState.activePullToken = nil
        switch result {
        case .success(let url):
            appState.previewPDFURL = url
            appState.keynotePullStatus = .succeeded
            setStatus("")
        case .failure(let error):
            if case .cancelled = error {
                appState.keynotePullStatus = .idle
                setStatus("")
            } else {
                appState.keynotePullStatus = .failed
                setStatus(error.localizedDescription)
            }
        }
    }
}

/// Shared action: convert the user's copied Keynote selection to a vector PDF.
/// Called by both the button in ContentView and the File menu in AppDelegate.
func triggerKeynoteClipboard(appState: AppState, setStatus: @escaping (String) -> Void) {
    guard appState.keynotePullStatus != .pulling else { return }
    let token = PullCancellationToken()
    appState.activePullToken = token
    appState.keynotePullStatus = .pulling
    setStatus(NSLocalizedString("status.keynote.pulling",
        comment: "Status: PDF export from Keynote in progress"))
    let clipboardPDF: Data? = {
        let pb = NSPasteboard.general
        return ["com.adobe.pdf", "Apple PDF pasteboard type"]
            .lazy
            .compactMap { pb.data(forType: NSPasteboard.PasteboardType($0)) }
            .first { !$0.isEmpty }
    }()
    pullFromKeynote(wantSelection: true, clipboardPDFData: clipboardPDF, cancellationToken: token) { result in
        appState.activePullToken = nil
        switch result {
        case .success(let url):
            appState.previewPDFURL = url
            appState.keynotePullStatus = .succeeded
            setStatus("")
        case .failure(let error):
            if case .cancelled = error {
                appState.keynotePullStatus = .idle
                setStatus("")
            } else {
                appState.keynotePullStatus = .failed
                setStatus(error.localizedDescription)
            }
        }
    }
}
