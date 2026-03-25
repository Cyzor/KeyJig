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

Two suites. Neither application class uses `inherits="application"` — doing so creates a cycle that hangs the app permanently on the first Apple Event (infinite loop in `-[NSScriptClassDescription supportsCommand:]`).

### Standard Suite (`????`)

Declares the base `application` class (`capp` / `NSApplication`) with three properties that Script Debugger uses to populate its Explorer header:

- `name` (`pnam`)
- `frontmost` (`pisf`) — `<cocoa key="isActive" />`
- `version` (`vers`)

Do **not** redeclare `get`, `set`, or `quit` here. Foundation registers those handlers at runtime; duplicating them in the SDEF causes duplicate-handler conflicts that produce the same -1712 timeout hang.

### KeyJig Suite (`VcIm`)

A second `application` class block (same `capp` code) adds the KeyJig-specific properties. Cocoa Scripting merges same-code classes across suites automatically — no `inherits` needed or wanted.

All 16 commands live here as siblings of the class, not nested inside it.

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

**Naming pitfalls:** Property names share the AppleScript namespace with built-ins.
- `SVG width` / `SVG height` — AppleScript parses `SVG` as a complete property reference, leaving `width`/`height` unresolved. Fixed by renaming to `pixel width` / `pixel height`.
- Plain `width` / `height` — clash with the built-in window property terms. Same fix applies.

---

## Commands (16 total)

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

## What Was Removed

- **`get SVG dimensions`** (`VcImGtDm`) — removed entirely. Returning a named `record-type` from an `NSScriptCommand` requires building a raw `NSAppleEventDescriptor` by hand, and even then the AE machinery returned -1708 (event not handled) before `performDefaultImplementation` was ever reached. The `pixel width` / `pixel height` properties on the application object cover the practical use case.

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