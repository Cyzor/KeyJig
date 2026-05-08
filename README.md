# KeyJig

**Import editable vector graphics into Apple Keynote.**

KeyJig is a macOS menu-bar utility that bridges vector artwork from Adobe Illustrator, Affinity Designer, Inkscape, and other SVG-capable tools into Keynote as native, editable Bézier paths.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

---

## Why KeyJig?

Keynote reads SVG natively, but standard Copy/Paste from Illustrator or Affinity Designer usually falls back to a static PDF image. KeyJig acts as a clipboard bridge: it intercepts the vector data and hands Keynote a payload that triggers the high-fidelity SVG importer. You can then **Break Apart** and **Make Editable** to control every node and path.

---

## Workflow

1. **Copy** your vector artwork in Illustrator, Affinity Designer, or any SVG tool (`⌘C`).
2. **Switch** to KeyJig — it detects the SVG and shows a preview.
3. **Bridge** by clicking **Copy to Clipboard**.
4. **Paste** in Keynote (`⌘V`).
5. **Break Apart** via *Format → Shapes and Lines → Break Apart* (or right-click the object).
6. **Make Editable** (optional) via the same menu.
7. **Modify** color, stroke, and anchor points like any native Keynote shape.

---

## Screenshots

_Coming soon._

---

## Installation

### Prerequisites

- macOS 11.3 (Big Sur) or later
- [Inkscape](https://inkscape.org/) — optional, only needed for PDF and `.ai` fallback. KeyJig auto-detects it at `/Applications/Inkscape.app`, `/opt/homebrew/bin/inkscape`, or `/usr/local/bin/inkscape`.

### Build from Source

```bash
git clone https://github.com/cyzor/keynote-vector-importer.git
```

Open `KeyJig.xcodeproj` in Xcode, select the **KeyJig** scheme, and Build (`⌘B`) or Run (`⌘R`).

### Distribution & Security

KeyJig ships as a Developer ID–signed, notarized, stapled `.app`. The release workflow enables the Hardened Runtime (`-o runtime`) so notarization passes. The App Sandbox stays off because KeyJig shells out to Inkscape and writes temp files for the Keynote clipboard handoff.

---

## Features

- **Clipboard bridging** — detects SVG on the clipboard and re-encodes it for Keynote.
- **File support** — open any `.svg` to preview and copy.
- **PDF/AI fallback** — converts via Inkscape when needed.
- **AppleScript** — fully scriptable for automation workflows.
- **Pure Swift/SwiftUI** — no bundled third-party libraries.

---

## AppleScript

KeyJig exposes 17 commands for scripting conversions, file operations, and window management.

```applescript
tell application "KeyJig"
    load SVG file "/Users/john/Documents/design.svg"
    convert
end tell
```

See [**docs/applescript.md**](./docs/applescript.md) for the full command reference, or open the dictionary in Script Editor via *File → Open Dictionary → KeyJig*.

---

## Documentation

- [**user_guide.md**](./docs/user_guide.md) — installation, usage modes, drag and drop, troubleshooting
- [**applescript.md**](./docs/applescript.md) — AppleScript command reference
- [**scripting_implementation.md**](./docs/scripting_implementation.md) — developer notes on the scripting layer

---

## Acknowledgments

KeyJig draws on, and takes a different technical approach than, [**SVG2Keynote**](https://github.com/eth-siplab/SVG2Keynote-gui) by [Jonathan Lampérth](https://www.linkedin.com/in/jonathan-lamperth-7059b418a) and [Christian Holz](https://www.christianholz.net) at the [Sensing, Interaction & Perception Lab](https://siplab.org), ETH Zürich. Where SVG2Keynote constructs Keynote's `.iwa` format directly via Protobuf, KeyJig leans on Keynote's built-in SVG importer (Keynote 10.0+).

Earlier builds used the [SVGWebView](https://github.com/ZeeZide/SVGWebView) Swift package by ZeeZide GmbH; the current preview is an in-house WebKit view.

---

## License

MIT License. See [LICENSE](./LICENSE).
