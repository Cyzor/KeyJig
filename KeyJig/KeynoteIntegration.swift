import Cocoa
import os

private let log = Logger(subsystem: "com.cyzor.KeyJig", category: "Keynote")

// MARK: - Error type

enum KeynoteInsertError: LocalizedError {
    case keynoteNotRunning
    case keynoteTooOld(String)
    case noDocumentOpen
    case accessibilityDenied
    case fileWriteError(Error)
    case pasteFailed

    var errorDescription: String? {
        switch self {
        case .keynoteNotRunning:
            return NSLocalizedString(
                "error.keynote.not_running",
                comment: "Error: Keynote is not running or has no document open")
        case .keynoteTooOld(let version):
            return String(
                format: NSLocalizedString(
                    "error.keynote.too_old",
                    comment: "Error: installed Keynote predates SVG import (needs 13.1+); %@ is the detected version"),
                version)
        case .noDocumentOpen:
            return NSLocalizedString(
                "error.keynote.no_document",
                comment: "Error: Keynote is running but has no open document")
        case .accessibilityDenied:
            return NSLocalizedString(
                "error.keynote.accessibility",
                comment: "Error: Accessibility access not granted")
        case .fileWriteError(let underlying):
            return underlying.localizedDescription
        case .pasteFailed:
            return NSLocalizedString(
                "error.keynote.paste_failed",
                comment: "Error: AX paste action did not succeed")
        }
    }
}

// MARK: - Keynote version

/// Version string of the user's Keynote (e.g. "14.5"), read from the app
/// bundle's Info.plist — no Apple Events, no launch required. Prefers the
/// running instance's bundle; falls back to the installed app. nil when
/// Keynote isn't installed or the plist is unreadable.
func keynoteVersionString() -> String? {
    let url = NSRunningApplication
        .runningApplications(withBundleIdentifier: "com.apple.iWork.Keynote")
        .first?.bundleURL
        ?? NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.iWork.Keynote")
    guard let url, let bundle = Bundle(url: url) else { return nil }
    return bundle.infoDictionary?["CFBundleShortVersionString"] as? String
}

/// Keynote gained SVG import in 13.1 (June 2023 iWork update); the push
/// pipeline pastes an SVG file URL, so anything older silently produces
/// nothing on the slide. Unknown versions pass — feature absence will
/// surface as a paste error, which beats wrongly blocking a capable Keynote.
private func keynoteSupportsSVGImport(_ version: String?) -> Bool {
    guard let version else { return true }
    let parts = version.split(separator: ".").compactMap { Int($0) }
    guard let major = parts.first else { return true }
    let minor = parts.count > 1 ? parts[1] : 0
    return major > 13 || (major == 13 && minor >= 1)
}

// MARK: - Public entry point

/// Writes svgData to a temp file and inserts it into the current Keynote slide.
///
/// Uses pasteboard + AX menu-item press (not keystroke simulation).
/// The general pasteboard is saved before writing and restored after Keynote
/// reads it, minimising disruption to clipboard contents.
///
/// Must be called on the main thread. Calls completion on the main thread.
func sendSVGToKeynote(svgData: String, completion: @escaping (KeynoteInsertError?) -> Void) {
    assert(Thread.isMainThread, "sendSVGToKeynote must be called on the main thread")

    // 1. Write SVG to a temp file — clipboard untouched so far.
    let tempURL = makeTempSVGURL()
    do {
        try sanitizeSVGForKeynote(svgData).write(to: tempURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
    } catch {
        log.error("Failed to write temp SVG: \(error.localizedDescription, privacy: .public)")
        completion(.fileWriteError(error))
        return
    }

    // 2. Verify Keynote is running.
    guard let keynoteApp = NSRunningApplication
        .runningApplications(withBundleIdentifier: "com.apple.iWork.Keynote").first
    else {
        completion(.keynoteNotRunning)
        return
    }

    // 2b. Version gate: SVG paste needs Keynote ≥ 13.1. Logged either way so
    //     reports from untested versions are triageable.
    let keynoteVersion = keynoteVersionString()
    log.info("push: Keynote version \(keynoteVersion ?? "unknown", privacy: .public)")
    if !keynoteSupportsSVGImport(keynoteVersion) {
        completion(.keynoteTooOld(keynoteVersion ?? "?"))
        return
    }

    // 3. Verify Keynote has a document open (NSAppleScript is synchronous;
    //    main thread only — the short timeout keeps a modally-blocked Keynote
    //    from beachballing KeyJig for the ~2-minute default AE timeout).
    var scriptError: NSDictionary?
    NSAppleScript(source: """
        tell application "Keynote"
            with timeout of 10 seconds
            if not (exists front document) then error number -1728
            end timeout
        end tell
    """)!.executeAndReturnError(&scriptError)
    if scriptError != nil {
        completion(.noDocumentOpen)
        return
    }

    // 4. Check Accessibility permission. Prompts on first call if not yet granted.
    if !AXIsProcessTrusted() {
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        completion(.accessibilityDenied)
        return
    }

    // 5. Snapshot the general pasteboard so we can restore it after the paste.
    let snapshot = snapshotGeneralPasteboard()

    // 6. Place the SVG file URL on the general pasteboard.
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.writeObjects([tempURL as NSURL])
    // Remember the count of *our* write so the delayed restore can detect a
    // pasteboard change by the user (or another app) and stand down.
    let pasteboardChangeCount = pb.changeCount

    // 7. Bring Keynote forward.
    let pid = keynoteApp.processIdentifier
    if #available(macOS 14.0, *) {
        keynoteApp.activate()
    } else {
        keynoteApp.activate(options: .activateIgnoringOtherApps)
    }

    // 8. Click the Paste menu item by its keyboard shortcut character — language-independent,
    //    no keystroke simulation.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        let ok = pressMenuItemWithCmdChar("v", appPID: pid)
        log.info("AX paste press result: \(ok, privacy: .public)")

        // 9. Report the result now; restore the pasteboard later. The restore
        //    is deliberately generous (1.5 s): a busy Keynote can resolve the
        //    paste well after the AX press returns, and restoring too early
        //    makes it paste the user's old clipboard instead. The file URL on
        //    the pasteboard stays valid throughout, so a late restore is safe.
        completion(ok ? nil : .pasteFailed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // Skip the restore if something else (the user, another app)
            // changed the pasteboard in the meantime — don't clobber it.
            if NSPasteboard.general.changeCount == pasteboardChangeCount {
                restoreGeneralPasteboard(snapshot)
            }
        }
    }
}

// MARK: - Pasteboard snapshot / restore

private struct PasteboardEntry {
    let type: NSPasteboard.PasteboardType
    let data: Data
}

/// Per-flavor ceiling for the snapshot. A copied Keynote slide can carry tens
/// of MB in its native flavor; holding (and later re-writing) that much data
/// for a best-effort clipboard restore isn't worth the memory and main-thread
/// cost, so oversized flavors are dropped from the snapshot.
private let maxSnapshotFlavorBytes = 16 * 1024 * 1024

private func snapshotGeneralPasteboard() -> [[PasteboardEntry]] {
    let pb = NSPasteboard.general
    return (pb.pasteboardItems ?? []).map { item in
        item.types.compactMap { type in
            guard let data = item.data(forType: type) else { return nil }
            guard data.count <= maxSnapshotFlavorBytes else {
                log.info("pasteboard snapshot: dropping \(type.rawValue, privacy: .public) (\(data.count, privacy: .public) bytes)")
                return nil
            }
            return PasteboardEntry(type: type, data: data)
        }
    }
}

private func restoreGeneralPasteboard(_ snapshot: [[PasteboardEntry]]) {
    guard !snapshot.isEmpty else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    let items: [NSPasteboardItem] = snapshot.map { entries in
        let item = NSPasteboardItem()
        for e in entries { item.setData(e.data, forType: e.type) }
        return item
    }
    pb.writeObjects(items)
}

// MARK: - AX menu-item press

/// Walks the menu bar of the given process looking for a menu item whose
/// keyboard shortcut character matches `char` with no extra modifiers (i.e.
/// Command-only, since Command is implicit for menu shortcuts).
/// Returns true if the item was found and pressed.
func pressMenuItemWithCmdChar(_ char: String, appPID: pid_t) -> Bool {
    let app = AXUIElementCreateApplication(appPID)

    var menuBarRef: AnyObject?
    guard AXUIElementCopyAttributeValue(
        app, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
          let menuBar = menuBarRef else {
        log.error("Could not get Keynote menu bar")
        return false
    }
    let menuBarElement = menuBar as! AXUIElement

    var topItemsRef: AnyObject?
    guard AXUIElementCopyAttributeValue(
        menuBarElement, kAXChildrenAttribute as CFString, &topItemsRef) == .success,
          let topItems = topItemsRef as? [AXUIElement] else { return false }

    for topItem in topItems {
        // Each menu-bar item has one child: the drop-down AXMenu.
        guard let menu = axFirstChild(of: topItem) else { continue }

        var itemsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            menu, kAXChildrenAttribute as CFString, &itemsRef) == .success,
              let items = itemsRef as? [AXUIElement] else { continue }

        for item in items {
            var cmdCharRef: AnyObject?
            guard AXUIElementCopyAttributeValue(
                item, "AXMenuItemCmdChar" as CFString, &cmdCharRef) == .success,
                  let cmdChar = cmdCharRef as? String,
                  cmdChar.lowercased() == char else { continue }

            // Modifiers value 0 = Command only (Command is always implicit).
            var modRef: AnyObject?
            AXUIElementCopyAttributeValue(
                item, "AXMenuItemCmdModifiers" as CFString, &modRef)
            guard (modRef as? Int) == 0 else { continue }

            let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
            log.debug("Pressed Cmd+\(char, privacy: .public), AX result \(result.rawValue, privacy: .public)")
            return result == .success
        }
    }

    log.error("No Cmd+\(char, privacy: .public) menu item found in Keynote")
    return false
}

private func axFirstChild(of element: AXUIElement) -> AXUIElement? {
    var ref: AnyObject?
    guard AXUIElementCopyAttributeValue(
        element, kAXChildrenAttribute as CFString, &ref) == .success,
          let children = ref as? [AXUIElement] else { return nil }
    return children.first
}
