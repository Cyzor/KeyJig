# AppleScript Reference

KeyJig is fully scriptable via AppleScript. Use Script Editor, Automator, shell scripts, or any other automation tool to drive SVG workflows without touching the UI.

---

## Requirements

- macOS 11.5 or later
- **Inkscape** (optional) — required only for `convert clipboard` when the clipboard holds PDF/AI data
  - Install via [inkscape.org](https://inkscape.org/) or `brew install inkscape`

---

## Quick Reference

### Application Properties

All read-only. Access via `tell application "KeyJig" to get <property>`.

| Property | Returns |
|---|---|
| `SVG` | Full SVG text of the loaded file |
| `SVG file path` | POSIX path of the loaded file, or `""` |
| `pixel width` | Width string parsed from the SVG |
| `pixel height` | Height string parsed from the SVG |
| `file size` | Human-readable size, e.g. `"42.3 KB"` |
| `SVG creator` | Creator metadata from the SVG, or `""` |
| `document name` | Loaded file's name without extension, or `""` |
| `result file path` | POSIX path of the most recent output file — the pulled Keynote PDF if one is loaded, otherwise the staged SVG bridge file, or `""` |

### All Commands

| Command | What it does | Returns |
|---|---|---|
| `convert` | Convert loaded SVG to Keynote format, copy to clipboard | boolean |
| `clear` | Clear the loaded SVG from memory | boolean |
| `load SVG file` | Load an SVG from a file path | boolean |
| `open file` | Open the file-picker dialog | boolean |
| `check clipboard` | Return SVG string from clipboard, or `""` | text |
| `check for convertible` | True if clipboard has PDF/vector data | boolean |
| `convert clipboard` | Convert clipboard PDF/vector to SVG via Inkscape | text |
| `get SVG` | Return the currently loaded SVG as text | text |
| `get SVG file path` | Return the loaded file's path, or `""` | text |
| `get SVG dimensions` | Return `{width:"…", height:"…"}` record | record |
| `get file size` | Return human-readable file size (e.g. `"42.1 KB"`) | text |
| `get SVG creator` | Return creator metadata from the SVG, or `""` | text |
| `show main window` | Show the main application window | boolean |
| `show popover` | Show the menu bar popover | boolean |
| `new floating window` | Open a new floating window | boolean |
| `show about` | Show the About dialog | boolean |
| `show help` | Show help documentation | boolean |

### One-liners

```applescript
tell application "KeyJig" to activate
tell application "KeyJig" to convert
tell application "KeyJig" to clear
tell application "KeyJig" to load SVG file "/path/to/file.svg"
tell application "KeyJig" to get SVG
tell application "KeyJig" to get pixel width
tell application "KeyJig" to get pixel height
tell application "KeyJig" to check clipboard
tell application "KeyJig" to check for convertible
tell application "KeyJig" to new floating window
```

---

## Command Reference

### Core Operations

**`convert`** — Converts the loaded SVG to Keynote's native format and places the result on the clipboard. Switch to Keynote and paste with ⌘V.

**`clear`** — Removes the currently loaded SVG from memory.

---

### File Operations

**`load SVG file path`** — Loads an SVG from disk.

```applescript
tell application "KeyJig"
    load SVG file "/Users/yourname/Documents/logo.svg"
end tell
```

**`open file`** — Opens the system file-picker so the user can choose an SVG interactively.

---

### Clipboard Operations

**`check clipboard`** — Returns the SVG string if the clipboard contains native SVG data, or an empty string if not. Does not modify the clipboard.

**`check for convertible`** — Returns `true` if the clipboard contains PDF or AI vector data that Inkscape can convert.

**`convert clipboard`** — Converts PDF/vector clipboard data to SVG using Inkscape. Blocks until conversion finishes (up to 30-second timeout). Returns the resulting SVG string, or `""` on failure.

---

### Information Queries

**`get SVG`** — Returns the full SVG text of the loaded file.

**`get SVG file path`** — Returns the file system path of the loaded SVG, or `""` if the SVG was loaded from the clipboard.

**`get SVG dimensions`** — Returns an AppleScript record `{width:"512", height:"384"}` parsed from the SVG. Equivalent to reading the `pixel width` / `pixel height` properties separately.

**`get file size`** — Returns a formatted string such as `"23.4 KB"`.

**`get SVG creator`** — Extracts the creator application name from the SVG metadata, or `""` if not present.

---

### Window Commands

**`show main window`**, **`show popover`**, **`new floating window`**, **`show help`** — All return `true`. Use these to surface the app UI from a script.

**`show about`** — Returns `true`, but presents a modal alert. All subsequent Apple Events block until the user dismisses it. Don't call this in unattended scripts or test loops.

---

## Practical Examples

### Load a file, convert, and report info

```applescript
tell application "KeyJig"
    activate
    load SVG file "/Users/yourname/Documents/diagram.svg"
    delay 0.5

    set w to pixel width
    set h to pixel height
    set sz to get file size
    set cr to get SVG creator

    display alert "Dimensions: " & w & " × " & h & return & ¬
                  "Size: " & sz & return & ¬
                  "Creator: " & cr

    convert
end tell
```

### Detect and convert clipboard content

```applescript
tell application "KeyJig"
    activate
    set svg to check clipboard

    if svg is not "" then
        convert
        display notification "SVG converted — paste into Keynote."
    else if check for convertible then
        set result to convert clipboard
        if result is not "" then
            convert
            display notification "PDF converted to SVG — paste into Keynote."
        else
            display alert "Conversion failed. Is Inkscape installed?"
        end if
    else
        display alert "No SVG or vector data found on the clipboard."
    end if
end tell
```

### Batch convert a list of files

```applescript
set svgFiles to {¬
    "/Users/yourname/Documents/icon1.svg", ¬
    "/Users/yourname/Documents/icon2.svg", ¬
    "/Users/yourname/Documents/icon3.svg"}

tell application "KeyJig"
    activate
    repeat with f in svgFiles
        load SVG file f
        delay 0.5
        convert
        delay 0.5
        display notification "Converted: " & f
    end repeat
    display alert "Done — " & (count of svgFiles) & " files converted."
end tell
```

### Process an entire folder

```applescript
set folderPath to POSIX path of (choose folder with prompt "Select folder of SVG files")

tell application "Finder"
    set svgFiles to (every file in folder folderPath whose name ends with ".svg") as list
end tell

tell application "KeyJig"
    activate
    set n to 0
    repeat with f in svgFiles
        load SVG file (POSIX path of f)
        delay 0.5
        convert
        delay 0.5
        set n to n + 1
    end repeat
    display alert "Processed " & n & " SVG files."
end tell
```

### Export the loaded SVG to a file

```applescript
tell application "KeyJig"
    set svgText to get SVG
    if svgText is "" then
        display alert "No SVG is currently loaded."
    else
        set outPath to "/Users/yourname/Desktop/exported.svg"
        set fh to open for access POSIX file outPath with write permission
        set eof fh to 0
        write svgText to fh
        close access fh
        display alert "Saved to: " & outPath
    end if
end tell
```

### Automator Quick Action (Finder integration)

Save as an Automator Quick Action to add KeyJig to the Finder right-click menu:

```applescript
on run {input, parameters}
    set selectedFile to item 1 of input
    tell application "KeyJig"
        activate
        load SVG file (POSIX path of selectedFile)
        delay 1
        convert
    end tell
    return input
end run
```

### Folder Action (auto-convert on arrival)

```applescript
on adding folder items to thisFolder after receiving addedItems
    repeat with anItem in addedItems
        set fp to POSIX path of anItem
        if fp ends with ".svg" then
            tell application "KeyJig"
                load SVG file fp
                delay 1
                convert
            end tell
        end if
    end repeat
end adding folder items to
```

---

## Error Handling

Always wrap file operations in `try/on error` blocks:

```applescript
tell application "KeyJig"
    try
        load SVG file "/path/to/file.svg"
        convert
    on error errMsg number errNum
        display alert "Error " & errNum & ": " & errMsg
    end try
end tell
```

`convert clipboard` is synchronous from AppleScript's perspective — the script blocks until the conversion finishes or the 30-second timeout expires. A returned empty string means failure or timeout.

---

## Calling from Other Languages

**Shell**

```bash
# Single command
osascript -e 'tell application "KeyJig" to convert'

# Script file
osascript /path/to/script.scpt

# With a shell variable
osascript -e "tell application \"KeyJig\" to load SVG file \"$HOME/Documents/test.svg\""
```

**Python**

```python
import subprocess

script = '''
tell application "KeyJig"
    load SVG file "/Users/yourname/Documents/test.svg"
    convert
end tell
'''
subprocess.run(["osascript", "-e", script], check=True)
```

---

## Tips and Troubleshooting

| Problem | Solution |
|---|---|
| `"Connection is invalid"` error | Make sure the app is running; call `activate` first |
| Commands missing in Script Editor | Rebuild the app in Xcode so the SDEF is recompiled |
| `convert clipboard` returns `""` | Verify Inkscape is installed (`which inkscape`) and the clipboard actually contains PDF/AI data |
| Very large SVGs return truncated text | AppleScript has text size limits; use file-based workflows for large SVGs |
| File dialog opens unexpectedly | `open file` is interactive by design — omit it in unattended scripts |

### Viewing the live dictionary

1. Open **Script Editor** (`/Applications/Utilities/`)
2. **File > Open Dictionary**
3. Select **KeyJig**
4. Browse the **KeyJig Suite** for all commands with inline descriptions