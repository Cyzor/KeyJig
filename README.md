# KeyJig

![App icon](docs/img/keyjigicon-256.png)

**Bridge editable vector graphics into — and out of — Apple Keynote.**

KeyJig is a Mac utility that sits between your vector tools and Apple Keynote. It works both ways: send SVG artwork onto a Keynote slide as editable paths, or extract vector content from a slide for use in page layout tools, print workflows, or wherever you need clean vector output.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-11.5+-blue.svg)](#installation)
[![Release](https://img.shields.io/github/v/release/Cyzor/KeyJig)](https://github.com/Cyzor/KeyJig/releases/latest)

---

## Why it exists

Keynote 10+ has a native SVG importer, but copying and pasting from Illustrator or Affinity Designer sends Keynote a flattened, uneditable PDF. KeyJig re-encodes the artwork so Keynote imports it as native, editable paths you can Break Apart and modify freely.

---

## Workflows

### Send artwork to Keynote

![workflow diagram](docs/img/workflow-diagram.svg)

1. **Copy** vector artwork in Illustrator, Affinity Designer, or any app that puts SVG on the clipboard (`⌘C`).
2. **Switch** to KeyJig — it detects the SVG and shows a preview.
3. **Send it to Keynote** in any of three ways:
   - **Drag** the preview directly onto a slide.
   - **⌘K** (or right-click the preview) to copy it to the clipboard, then paste in Keynote (`⌘V`).
   - **⌘D / Place in Keynote** to insert it onto the current slide automatically.
4. **Break Apart** in Keynote via *Format → Shapes and Lines → Break Apart* (or right-click the object).
5. Optionally **Make Editable**, then adjust color, stroke, and anchor points like any native Keynote shape.

### Pull content from Keynote

Keynote presentations often hold carefully composed vector artwork. These commands let you get it back out at full quality.

- **⌘R / Pull Slide** — exports the current Keynote slide as a vector PDF and loads it into the preview. Hold Option to reveal this button.
- **⌘E / Extract Selection** — select objects in Keynote and press `⌘C`, then press ⌘E in KeyJig. It pastes your selection into a scratch document, exports just those objects as a clean vector PDF, and discards the scratch doc — your original slide stays untouched. Hold Option to reveal this button.

---

## Screenshots

_Screenshots coming soon._

---

## Installation

### Requirements

- macOS 11.5 (Big Sur) or later
- [Inkscape](https://inkscape.org/) — optional; needed only for PDF and `.ai` conversion. KeyJig auto-detects it at `/Applications/Inkscape.app`, `/opt/homebrew/bin/inkscape`, or `/usr/local/bin/inkscape`.

### Download

Download the latest signed and notarized build from [Releases](https://github.com/Cyzor/KeyJig/releases/latest). Drag the app into `/Applications` and open it.

### Build from Source

```bash
git clone https://github.com/cyzor/KeyJig.git
```

Open `KeyJig.xcodeproj` in Xcode, select the **KeyJig** scheme, and Build (`⌘B`) or Run (`⌘R`).

---

## Features

- **Clipboard auto-detect** — the preview updates the moment an SVG lands on the clipboard, so switching to KeyJig from your drawing app is all it takes.
- **Drag-and-drop send** — drag the preview straight onto a Keynote slide.
- **Place in Keynote** — inserts the SVG onto the current slide via the Accessibility API, no manual paste needed.
- **Pull Slide** — exports the current Keynote slide as a vector PDF.
- **Extract Selection** — extracts only the selected Keynote objects as a clean vector PDF; non-contiguous selections work correctly.
- **PDF/AI conversion** — converts PDF and Adobe Illustrator files to SVG via Inkscape when Keynote's native importer isn't enough.
- **File open** — load any `.svg`, `.pdf`, or `.ai` file directly.
- **Multiple windows** — open independent viewer windows for side-by-side work.
- **AppleScript** — 17 commands covering conversion, file import/export, and window control.
- **No bundled libraries** — pure Swift; no third-party frameworks ship inside the app binary.

---

## AppleScript

KeyJig supports scripted conversions, file operations, and window management from AppleScript.

```applescript
tell application "KeyJig"
    load SVG file "/Users/john/Documents/design.svg"
    convert
end tell
```

See [**docs/applescript.md**](./docs/applescript.md) for the full command reference, or open the dictionary in Script Editor via *File → Open Dictionary → KeyJig*.

---

## Permissions

- **Accessibility access** — needed for Place in Keynote and Extract Selection. KeyJig uses the Accessibility API to invoke Keynote's Paste command directly, which is the only reliable way to insert content across apps regardless of keyboard layout or focus state.
- **No sandbox** — KeyJig runs without the App Sandbox so it can invoke Inkscape as a subprocess and write temporary files freely. It holds no entitlements beyond what those two tasks require.

KeyJig is notarized and built with Hardened Runtime.

---

## Documentation

- [**user_guide.md**](./docs/user_guide.md) — installation, usage modes, drag and drop, troubleshooting
- [**applescript.md**](./docs/applescript.md) — AppleScript command reference
- [**scripting_implementation.md**](./docs/scripting_implementation.md) — developer notes on the scripting layer

---

## Acknowledgments

KeyJig draws inspiration from [**SVG2Keynote**](https://github.com/eth-siplab/SVG2Keynote-gui) by [Jonathan Lampérth](https://www.linkedin.com/in/jonathan-lamperth-7059b418a) and [Christian Holz](https://www.christianholz.net) at the [Sensing, Interaction & Perception Lab](https://siplab.org), ETH Zürich, but takes a different technical approach. Where SVG2Keynote writes Keynote's `.iwa` format directly via Protobuf, KeyJig drives Keynote's built-in SVG importer (Keynote 10.0+).

When installed, KeyJig delegates certain operations to three open-source tools it auto-detects but does not bundle or distribute:

- [**Inkscape**](https://inkscape.org/) — PDF and `.ai` → SVG conversion.
- [**Ghostscript**](https://www.ghostscript.com/) — high-fidelity PDF crop and rewrite.
- [**MuPDF**](https://mupdf.com/) — lightweight alternative to Ghostscript for the same crop operations.

None are required. KeyJig works without them; they expand what it can do.

---

## License

MIT License. See [LICENSE](./LICENSE).