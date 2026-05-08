# KeyJig — AppleScript Implementation Notes

Implementation reference for the AppleScript scripting layer. Covers architecture decisions, known pitfalls, and the final working state.

---

## Files Involved

| File | Role |
|---|---|
| `KeyJig/KeyJig.sdef` | Scripting definition — commands, properties, event codes |
| `KeyJig/ScriptingCommands.swift` | `NSScriptCommand` subclasses, one per command |
| `KeyJig/AppDelegate.swift` | `@objc dynamic` properties for Explorer visibility |
| `KeyJig/KeyJig.xcodeproj/project.pbxproj` | `ScriptingCommands.swift` must be listed in both the file-reference group and the compile-sources build phase |

---

## SDEF Structure

One suite — `KeyJig Suite` (`VcIm`). Cocoa Scripting serves the standard `name`, `frontmost`, and `version` properties on `NSApplication` natively, so the SDEF doesn't redeclare them. Adding them back would conflict with Foundation's built-in handlers.

The `application` class (`capp` / `NSApplication`) does **not** use `inherits="application"` — doing so creates a cycle that hangs the app permanently on the first Apple Event (infinite loop in `-[NSScriptClassDescription supportsCommand:]`).

Do **not** redeclare `get`, `set`, or `quit`. Foundation registers those handlers at runtime; duplicating them in the SDEF causes duplicate-handler conflicts that produce -1712 timeout hangs.

All 17 commands live as siblings of the class, not nested inside it.

---

## Application Properties

Backed by `@objc dynamic` computed vars on `AppDelegate`, forwarded from `NSApplication` via an extension in `ScriptingCommands.swift`. All read-only.

| Name | Code | Cocoa key | Returns |
|---|---|---|---|
| `SVG` | `SVGc` | `scriptingSVG` | Full SVG text of the loaded file |
| `SVG file path` | `SVGp` | `scriptingSVGFilePath` | POSIX path, or `""` |
| `pixel width` | `SVGw` | `scriptingSVGWidth` | Width string extracted from SVG |
| `pixel height` | `SVGh` | `scriptingSVGHeight` | Height string extracted from SVG |
| `file size` | `SVGs` | `scriptingFileSize` | Human-readable size, e.g. `"42.3 KB"` |
| `SVG creator` | `SVGr` | `scriptingSVGCreator` | Creator metadata, or `""` |
| `document name` | `SVGd` | `scriptingDocumentName` | Loaded file's basename without extension, or `""` |

**Naming pitfalls:** Property names share the AppleScript namespace with built-ins.
- `SVG width` / `SVG height` — AppleScript parses `SVG` as a complete property reference, leaving `width`/`height` unresolved. Fixed by renaming to `pixel width` / `pixel height`.
- Plain `width` / `height` — clash with the built-in window property terms. Same fix applies.

---

## Commands (17 total)

All event codes are exactly 8 characters. All commands are direct children of the suite, not nested inside the class.

### Core

| Name | Code | Class | Returns |
|---|---|---|---|
| `convert` | `VcImCnvt` | `ConvertCommand` | `boolean` |
| `clear` | `VcImCler` | `ClearCommand` | `boolean` |

### File

| Name | Code | Class | Returns |
|---|---|---|---|
| `load SVG file` | `VcImLdSV` | `LoadSVGFileCommand` | `boolean` — takes POSIX path as direct parameter |
| `open file` | `VcImOpnF` | `OpenFileCommand` | `boolean` — shows panel asynchronously |

### Clipboard

| Name | Code | Class | Returns |
|---|---|---|---|
| `check clipboard` | `VcImChCB` | `CheckClipboardCommand` | `text` — SVG string or `""` |
| `check for convertible` | `VcImChCV` | `CheckConvertibleCommand` | `boolean` |
| `convert clipboard` | `VcImCvCB` | `ConvertClipboardCommand` | `text` — blocks up to 30 s |

### Queries

| Name | Code | Class | Returns |
|---|---|---|---|
| `get SVG` | `VcImGtSV` | `GetSVGCommand` | `text` |
| `get SVG file path` | `VcImGtFP` | `GetSVGFilePathCommand` | `text` |
| `get SVG dimensions` | `VcImGtDm` | `GetSVGDimensionsCommand` | `record` — `{width:"…", height:"…"}` |
| `get file size` | `VcImGtSz` | `GetFileSizeCommand` | `text` |
| `get SVG creator` | `VcImGtCr` | `GetSVGCreatorCommand` | `text` |

### Window Management

| Name | Code | Class | Returns |
|---|---|---|---|
| `show main window` | `VcImShMW` | `ShowMainWindowCommand` | `boolean` |
| `show popover` | `VcImShPo` | `ShowPopoverCommand` | `boolean` |
| `new floating window` | `VcImNwFW` | `NewFloatingWindowCommand` | `boolean` |

### Help & Info

| Name | Code | Class | Returns |
|---|---|---|---|
| `show about` | `VcImAbut` | `ShowAboutCommand` | `boolean` |
| `show help` | `VcImHelp` | `ShowHelpCommand` | `boolean` |

---

## Threading

`performDefaultImplementation()` is called on the main thread by the AppleScript machinery. Most commands call `AppState` directly — safe since they're already on the main thread.

`convert clipboard` is the exception: `convertClipboardPDFToSVG()` dispatches Inkscape work to a background queue and callbacks on the main queue. Blocking main while waiting for the callback would deadlock. Solution:

1. Call `suspendExecution()` to tell the AE machinery the result will arrive asynchronously.
2. Signal a `DispatchSemaphore` from the Inkscape callback.
3. Wait on the semaphore from a **background** thread so the main run loop stays free.
4. Call `resumeExecution(withResult:)` back on the main queue once the semaphore fires.

---

## State Access

Commands reach `AppState` through the `frontState()` helper (top of `ScriptingCommands.swift`), which returns the `AppState` of the key window, falling back to the primary window. There is no `AppState.shared` singleton.

Properties on `AppDelegate` use `frontWindowState` (a private computed var with the same fallback logic).

---

## Records as Results

`get SVG dimensions` returns a record. The earlier attempt to declare a *named* `record-type` in the SDEF and return it from `NSScriptCommand` failed with -1708 (event not handled) — the AE machinery rejected the event before `performDefaultImplementation` ran. The current implementation declares the result as a generic `<result type="record" />` in the SDEF and returns a Swift `[String: String]` dictionary, which Cocoa Scripting auto-bridges to an AppleScript record. The `pixel width` / `pixel height` properties cover the same use case for callers that prefer scalar reads.

---

## Known Good State

Verified with `osascript` against a Debug build:

```applescript
tell application "KeyJig"
    load SVG file "/path/to/file.svg"  --> true
    get SVG file path                  --> "/path/to/file.svg"
    get file size                      --> "93 B"
    pixel width                        --> "100"
    pixel height                       --> "100"
    convert                            --> true
end tell
```

Script Debugger Explorer tab shows `SVG`, `SVG file path`, `pixel width`, `pixel height`, `file size`, and `SVG creator` populated when a file is loaded.