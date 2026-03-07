# VectorImporter

**A lightweight bridge for getting editable vector graphics into Apple Keynote.**

Originally developed as **SVG2Keynote** by [Jonathan Lampérth](https://www.linkedin.com/in/jonathan-lamperth-7059b418a) and [Christian Holz](https://www.christianholz.net) at the [Sensing, Interaction & Perception Lab](https://siplab.org), ETH Zürich.


VectorImporter converts graphics from applications such as Adobe Illustrator, Affinity Designer, and Inkscape into native, editable Bezier paths in Apple Keynote.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

---

## Why use VectorImporter?

Apple Keynote can read SVG files, but it is often inaccessible through standard Copy/Paste from tools like Adobe Illustrator or Affinity Designer (which usually fall back to static PDF images).

**VectorImporter** acts as a clipboard "bridge." It intercepts vector data and feeds it to Keynote in a format that triggers its high-fidelity native importer. This allows you to immediately **"Make Editable"** and have full control over every node and path.

### The Workflow:
1. **Copy:** Select your vector artwork in Illustrator, Affinity Designer, or any SVG-supporting tool and press `⌘C`.
2. **Bridge:** Click **"Bridge Clipboard to Keynote"** in VectorImporter.
3. **Paste:** Go to Keynote and press `⌘V`.
4. **Break:** Choose **Format > Shapes and Lines > Break Apart**.  Or right-click the pasted object and choose **Break Apart**.
5. **Edit:** (Optional) Choose **Format > Shapes and Lines > Make Editable**.  Or right-click the pasted object and choose **Make Editable**.
6. **Modify:** Now that the pasted object is a native Keynote shape, freely alter its color, stroke, and anchor points.


---

## Installation

### Prerequisites
- macOS 10.15 (Catalina) or later.
- No external libraries (Protobuf, Snappy, etc.) are required.

### Build from Source
1. Clone the repository:
   ```bash
   git clone https://github.com/cyzor/keynote-vector-importer.git
   ```
2. Open `VectorImporter.xcodeproj` in Xcode.
3. Select the **VectorImporter** scheme and click **Build** (`⌘B`) or **Run** (`⌘R`).

---

## Features

- **Clipboard Bridging:** Automatically detects SVG data on your clipboard and prepares it for Keynote.
- **File Support:** Open any `.svg` file directly to preview and copy it for Keynote.
- **Zero Dependencies:** The app is 100% Swift and SwiftUI, making it lightweight and easy to maintain.
- **PDF Fallback:** If native import isn't sufficient, use the "PDF Fallback" (requires [Inkscape](https://inkscape.org/)) to copy as a high-quality vector image.

---

## Technical History

The original project utilized a custom C++ library and Google Protobuf to manually construct Keynote's internal `.iwa` format. While powerful, this was prone to breaking whenever Apple updated Keynote's internal structures or when Protobuf versions changed.

The current version of **VectorImporter** leverages Keynote's native SVG support added in version 10.0+. By providing a temporary file URL as a clipboard promise, we bypass the need for custom binary construction while achieving the same high-fidelity, editable results.

---

## License

This project is licensed under the MIT License.
