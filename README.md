# KeyJig

**Slightly easier way to import editable vector graphics into Apple Keynote.**

Originally developed as **SVG2Keynote** by [Jonathan Lampérth](https://www.linkedin.com/in/jonathan-lamperth-7059b418a) and [Christian Holz](https://www.christianholz.net) at the [Sensing, Interaction & Perception Lab](https://siplab.org), ETH Zürich.


KeyJig converts graphics from applications such as Adobe Illustrator, Affinity Designer, and Inkscape into native, editable Bezier paths in Apple Keynote.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

---

## Why use KeyJig?

Apple Keynote can read SVG files, but it is often inaccessible through standard Copy/Paste from tools like Adobe Illustrator or Affinity Designer (which usually fall back to static PDF images).

**KeyJig** acts as a clipboard "bridge." It intercepts vector data and feeds it to Keynote in a format that triggers its high-fidelity native importer. This allows you to immediately **"Make Editable"** and have full control over every node and path.

### The Workflow:
1. **Copy:** Select your vector artwork in Illustrator, Affinity Designer, or any SVG-supporting tool and press `⌘C`.
2. **Switch:** Bring KeyJig to the front. It detects the SVG on your clipboard automatically and shows a preview.
3. **Bridge:** Click **"Copy to Clipboard"** in KeyJig.
4. **Paste:** Go to Keynote and press `⌘V`.
5. **Break:** Choose **Format > Shapes and Lines > Break Apart**.  Or right-click the pasted object and choose **Break Apart**.
6. **Edit:** (Optional) Choose **Format > Shapes and Lines > Make Editable**.  Or right-click the pasted object and choose **Make Editable**.
7. **Modify:** Now that the pasted object is a native Keynote shape, freely alter its color, stroke, and anchor points.


---

## Installation

### Prerequisites
- macOS 11.3 (Big Sur) or later.
- No external libraries (Protobuf, Snappy, etc.) are required.

### Build from Source
1. Clone the repository:
   ```bash
   git clone https://github.com/cyzor/keynote-vector-importer.git
   ```
2. Open `KeyJig.xcodeproj` in Xcode.
3. Select the **KeyJig** scheme and click **Build** (`⌘B`) or **Run** (`⌘R`).

---

## Features

- **Clipboard Bridging:** Automatically detects SVG data on your clipboard and prepares it for Keynote.
- **File Support:** Open any `.svg` file directly to preview and copy it for Keynote.
- **Zero Dependencies:** The app is 100% Swift and SwiftUI, making it lightweight and easy to maintain.
- **PDF Fallback:** If native import isn't sufficient, use the "PDF Fallback" (requires [Inkscape](https://inkscape.org/)) to copy as a high-quality vector image.
- **AppleScript Automation:** Fully scriptable via AppleScript for integration with workflows, automation tools, and other applications.

---

## AppleScript Automation

KeyJig is fully scriptable via AppleScript, allowing you to automate SVG conversions, file operations, and window management. 

### Quick Example

```applescript
tell application "KeyJig"
    load SVG file "/Users/john/Documents/design.svg"
    convert
end tell
```

### Available Commands

- **Core Operations:** `convert`, `clear`
- **File Operations:** `load SVG file`, `open file`
- **Clipboard:** `check clipboard`, `check for convertible`, `convert clipboard`
- **Information:** `get SVG`, `get SVG file path`, `get file size`, `get SVG creator`
- **Windows:** `show main window`, `show popover`, `new floating window`
- **Help:** `show about`, `show help`

For complete documentation, syntax examples, and advanced workflows, see [**applescript.md**](./docs/applescript.md).

### View the Dictionary

To see all available commands in Script Editor:
1. Open **Script Editor** (in Applications > Utilities)
2. Go to **File > Open Dictionary**
3. Select **KeyJig**

---

## Documentation

- [**user_guide.md**](./docs/user_guide.md) — Installation, usage modes, importing SVGs, drag and drop, and troubleshooting
- [**applescript.md**](./docs/applescript.md) — Complete AppleScript command reference and examples
- [**scripting_implementation.md**](./docs/scripting_implementation.md) — Technical implementation notes for developers

---

## Technical History

The original project utilized a custom C++ library and Google Protobuf to manually construct Keynote's internal `.iwa` format. While powerful, this was prone to breaking whenever Apple updated Keynote's internal structures or when Protobuf versions changed.

The current version of **KeyJig** leverages Keynote's native SVG support added in version 10.0+. By providing a temporary file URL as a clipboard promise, we bypass the need for custom binary construction while achieving the same high-fidelity, editable results.

---

## License

This project is licensed under the MIT License.
