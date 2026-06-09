import Cocoa

// MARK: - NSApplication Extension for Scripting Properties
//
// AppleScript accesses application properties via KVC on NSApplication.
// This extension forwards those calls to AppDelegate, which maintains
// the actual state via frontWindowState.

extension NSApplication {
    @objc dynamic var scriptingSVG: String {
        return (delegate as? AppDelegate)?.scriptingSVG ?? ""
    }

    @objc dynamic var scriptingSVGFilePath: String {
        return (delegate as? AppDelegate)?.scriptingSVGFilePath ?? ""
    }

    @objc dynamic var scriptingSVGWidth: String {
        return (delegate as? AppDelegate)?.scriptingSVGWidth ?? ""
    }

    @objc dynamic var scriptingSVGHeight: String {
        return (delegate as? AppDelegate)?.scriptingSVGHeight ?? ""
    }

    @objc dynamic var scriptingFileSize: String {
        return (delegate as? AppDelegate)?.scriptingFileSize ?? ""
    }

    @objc dynamic var scriptingSVGCreator: String {
        return (delegate as? AppDelegate)?.scriptingSVGCreator ?? ""
    }

    @objc dynamic var scriptingDocumentName: String {
        return (delegate as? AppDelegate)?.scriptingDocumentName ?? ""
    }
    @objc dynamic var scriptingResultFilePath: String {
        return (delegate as? AppDelegate)?.scriptingResultFilePath ?? ""
    }
}

// MARK: - Helpers

/// Returns the AppState for the frontmost window, falling back to the primary
/// window's state. Safe to call from the main thread only.
private func frontState() -> AppState? {
    guard let delegate = AppDelegate.shared else { return nil }
    if let wc = delegate.floatingWindows.first(where: { $0.window?.isKeyWindow == true }) {
        return wc.appState
    }
    return delegate.primaryWindowController?.appState
}

// MARK: - Core SVG Operations

/// Convert the loaded SVG to Keynote format and copy it to the clipboard.
/// performDefaultImplementation runs on the main thread (AppleScript machinery
/// guarantees this), so all AppState access here is safe without further dispatch.
@objc(ConvertCommand)
class ConvertCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let state = frontState() else { return NSNumber(value: false) }
        let svg = state.svgString
        guard !svg.isEmpty else { return NSNumber(value: false) }
        let ok = svgToClipboard(svgData: svg, appState: state) != nil
        return NSNumber(value: ok)
    }
}

/// Clear the currently loaded SVG from memory.
@objc(ClearCommand)
class ClearCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        if let state = frontState() {
            state.svgString = ""
            state.svgURL = ""
        }
        return NSNumber(value: true)
    }
}

// MARK: - File Operations

/// Load an SVG file from the path supplied as the direct parameter.
@objc(LoadSVGFileCommand)
class LoadSVGFileCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let path = directParameter as? String else {
            self.scriptErrorNumber = Int(errAEWrongDataType)
            self.scriptErrorString = "Expected a POSIX file path as the direct parameter."
            return NSNumber(value: false)
        }
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            if let state = frontState() {
                state.svgString = content
                state.svgURL = path
                return NSNumber(value: true)
            }
            return NSNumber(value: false)
        } catch {
            self.scriptErrorNumber = Int(-43)  // fnfErr: file not found / general file error
            self.scriptErrorString = "Could not read file: \(error.localizedDescription)"
            return NSNumber(value: false)
        }
    }
}

/// Open the system file-picker so the user can choose an SVG interactively.
/// Returns immediately (the dialog runs asynchronously on the main thread).
@objc(OpenFileCommand)
class OpenFileCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        AppDelegate.shared?.openSVGFile()
        return NSNumber(value: true)
    }
}

// MARK: - Clipboard Operations

/// Return the SVG string from the clipboard, or "" if none is found.
/// Clipboard reads don't touch the UI, so no dispatch needed.
@objc(CheckClipboardCommand)
class CheckClipboardCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        return convertClipboardToSVG()
    }
}

/// Return true if the clipboard contains PDF/vector data convertible via Inkscape.
@objc(CheckConvertibleCommand)
class CheckConvertibleCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        return NSNumber(value: clipboardHasConvertibleVectorData())
    }
}

/// Convert PDF/vector clipboard data to SVG using Inkscape.
///
/// convertClipboardPDFToSVG() dispatches its Inkscape work to a background
/// queue and calls back on the main queue.  Because performDefaultImplementation
/// runs on the main thread we cannot block main while waiting — doing so would
/// deadlock the main-queue callback.
///
/// Solution: hand the blocking wait off to a *background* thread via a
/// DispatchSemaphore, then block *that* thread.  The main thread stays free
/// to receive the callback.  We use suspendExecution / resumeExecution to
/// pause the AppleScript evaluation while the background thread waits.
@objc(ConvertClipboardCommand)
class ConvertClipboardCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // suspendExecution lets AppleScript know we will return asynchronously.
        suspendExecution()

        var resultSVG = ""
        let sema = DispatchSemaphore(value: 0)

        // convertClipboardPDFToSVG calls back on the main queue.
        convertClipboardPDFToSVG { svg in
            if let svg = svg, !svg.isEmpty {
                resultSVG = svg
                frontState()?.svgString = svg
            }
            sema.signal()
        }

        // Wait on a background thread so the main run loop stays unblocked.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = sema.wait(timeout: .now() + 30)
            // Always call resume on the main thread.
            DispatchQueue.main.async {
                self.resumeExecution(withResult: resultSVG)
            }
        }

        // Return value is ignored when suspendExecution has been called;
        // the real return goes through resumeExecutionWithResult above.
        return nil
    }
}

// MARK: - Information Queries

/// Return the currently loaded SVG as a text string.
@objc(GetSVGCommand)
class GetSVGCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        return frontState()?.svgString ?? ""
    }
}

/// Return the file-system path of the loaded SVG, or "" if loaded from clipboard.
@objc(GetSVGFilePathCommand)
class GetSVGFilePathCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        return frontState()?.svgURL ?? ""
    }
}

/// Return the dimensions of the loaded SVG as an AppleScript record: {width:"…", height:"…"}.
@objc(GetSVGDimensionsCommand)
class GetSVGDimensionsCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let svg = frontState()?.svgString, !svg.isEmpty,
            let dims = extractSVGDimensions(svgString: svg)
        else { return nil }
        return ["width": dims.width, "height": dims.height]
    }
}

/// Return the size of the loaded SVG as a human-readable string, e.g. "42.3 KB".
@objc(GetFileSizeCommand)
class GetFileSizeCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let svg = frontState()?.svgString else { return "" }
        return getFileSizeString(svgString: svg)
    }
}

/// Return creator metadata extracted from the SVG, or "".
@objc(GetSVGCreatorCommand)
class GetSVGCreatorCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let svg = frontState()?.svgString, !svg.isEmpty else { return "" }
        return extractSVGCreator(svgString: svg) ?? ""
    }
}

// MARK: - Window Management

/// Bring the main application window to the front.
@objc(ShowMainWindowCommand)
class ShowMainWindowCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        AppDelegate.shared?.showMainWindow()
        return NSNumber(value: true)
    }
}

/// Show the menu-bar popover.
@objc(ShowPopoverCommand)
class ShowPopoverCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        AppDelegate.shared?.togglePopover()
        return NSNumber(value: true)
    }
}

/// Open a new floating viewer window.
@objc(NewFloatingWindowCommand)
class NewFloatingWindowCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        AppDelegate.shared?.newFloatingWindow()
        return NSNumber(value: true)
    }
}

// MARK: - Help and Info

/// Show the About dialog.
@objc(ShowAboutCommand)
class ShowAboutCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        AppDelegate.shared?.showAbout()
        return NSNumber(value: true)
    }
}

/// Show help documentation.
@objc(ShowHelpCommand)
class ShowHelpCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        AppDelegate.shared?.showHelp()
        return NSNumber(value: true)
    }
}
