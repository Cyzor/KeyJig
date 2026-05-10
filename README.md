# KeyJig

![App icon](docs/img/keyjigicon-256.png)

**Import editable vector graphics into Apple Keynote.**

KeyJig is a macOS utility that helps import artwork from Adobe Illustrator, Affinity Designer, other SVG-capable tools into Keynote as native, editable Bézier paths.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-11.3+-blue.svg)](#installation)
[![Release](https://img.shields.io/github/v/release/cyzor/keynote-vector-importer)](https://github.com/cyzor/keynote-vector-importer/releases/latest)

---

## Purpose

Apple Keynote supports vector file formats natively, but standard Copy/Paste from Illustrator or Affinity Designer usually falls back to a flattened PDF image without further edibility. KeyJig acts as a clipboard bridge that intercepts vector data and hands Keynote a payload that triggers the high-fidelity SVG importer. You can then **Break Apart** and **Make Editable** to control every node and path.

---

## Workflow


![workflow diagram](docs/img/workflow-diagram.svg)


1. **Copy** your vector artwork in Illustrator, Affinity Designer, or similar application (`⌘C`).
2. **Switch** to KeyJig — it detects the SVG and shows a preview.
3. **Drag** preview image directly into a Keynote document.  Or **Bridge** by clicking **Copy to Clipboard** and then **Pasting** in Keynote (`⌘V`).
4. **Break Apart** in Keynote via *Format → Shapes and Lines → Break Apart* (or right-click the object).
5. **Make Editable** (optional) via the same menu.
6. **Modify** color, stroke, and anchor points like any native Keynote shape.

---

## Screenshots

_Workflow: Adobe Illustrator → KeyJig → Apple Keynote:_
![Workflow screenshot](docs/img/illustrator-keyjig-keynote.png)

_Keynote > Format > Shapes and Lines > Break Apart:_
![Keynote break apart](docs/img/keynote-break-apart.png)

_App Settings:_
![App settings](docs/img/settings.png)

---




## Installation

### Requirements

- macOS 11.3 (Big Sur) or later
- [Inkscape](https://inkscape.org/) — optional, only needed for PDF and `.ai` fallback. KeyJig auto-detects it at `/Applications/Inkscape.app`, `/opt/homebrew/bin/inkscape`, or `/usr/local/bin/inkscape`.

### Download

Download the latest signed version from [Releases](https://github.com/cyzor/KeyJig/releases/latest). Then drag into `/Applications` using the Finder and open.

### Build from Source

```bash
git clone https://github.com/cyzor/KeyJig.git
```

Open `KeyJig.xcodeproj` in Xcode, select the **KeyJig** scheme, and Build (`⌘B`) or Run (`⌘R`).

---

## Features

- **Clipboard bridging** — re-encodes SVG so Keynote imports it as editable paths.
- **Auto-detect** — picks up SVGs the moment they land on the clipboard, no button press needed.
- **Drag-and-drop** — drag the preview straight onto a slide; the clipboard stays untouched.
- **File open** — load any `.svg` from disk.
- **PDF/AI fallback** — converts via Inkscape when Keynote's native import isn't enough.
- **AppleScript** — rudimentary AppleEvent support for scripting and automation.
- **Pure Swift/SwiftUI** — no bundled third-party libraries.

---

## AppleScript

KeyJig exposes various commands for scripting conversions, file operations, and window management.

```applescript
tell application "KeyJig"
    load SVG file "/Users/john/Documents/design.svg"
    convert
end tell
```

See [**docs/applescript.md**](./docs/applescript.md) for the full command reference, or open the dictionary in Apple Script Editor via *File → Open Dictionary → KeyJig*.

---

## Security

KeyJig ships as a notarized app with Hardened Runtime enabled. The App Sandbox stays off because KeyJig may need to write temporary files or invoke the third-party app Inkscape.

---

## Documentation

- [**user_guide.md**](./docs/user_guide.md) — installation, usage modes, drag and drop, troubleshooting
- [**applescript.md**](./docs/applescript.md) — AppleScript command reference
- [**scripting_implementation.md**](./docs/scripting_implementation.md) — developer notes on the scripting layer

---

## Acknowledgments

KeyJig draws inspiration from [**SVG2Keynote**](https://github.com/eth-siplab/SVG2Keynote-gui) by [Jonathan Lampérth](https://www.linkedin.com/in/jonathan-lamperth-7059b418a) and [Christian Holz](https://www.christianholz.net) at the [Sensing, Interaction & Perception Lab](https://siplab.org), ETH Zürich, but takes a different technical approach. Where SVG2Keynote constructs Keynote's `.iwa` format directly via Protobuf, KeyJig leans on Keynote's built-in SVG importer (Keynote 10.0+).

Earlier builds used the [SVGWebView](https://github.com/ZeeZide/SVGWebView) Swift package by ZeeZide GmbH; the current preview is an in-house WebKit view.

---

## License

MIT License. See [LICENSE](./LICENSE).
