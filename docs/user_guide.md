# KeyJig User Guide

## Overview

KeyJig is a macOS utility that helps bring SVG vector graphics into Keynote. It handles format conversion and clipboard management.

---

## Installation

1. Build the app in Xcode and run it.
2. The KeyJig icon appears in the menu bar.
3. Optionally install [Inkscape](https://inkscape.org/) to enable the PDF fallback feature.

---

## Using KeyJig

### Menu Bar Popover

Click the KeyJig icon in the menu bar to open a compact popover. Click the icon again, or click anywhere outside the popover, to dismiss it.

Use this mode for quick, one-off imports while work stays focused in another app.

### Floating Window

Open a persistent, resizable window that stays on screen while work continues.

- **File > New Viewer** or **Cmd+Shift+N** opens a new window.
- Multiple floating windows can remain open at the same time.
- Each window can move, resize, and minimize independently.
- Window position and size persist between sessions.

Use this mode for working with multiple SVGs, comparing files side by side, or keeping KeyJig visible on a secondary display.

---

## Importing SVGs

### Open an SVG File

Click **Open SVG File…** (or use **File > Open SVG… / Cmd+O**) to browse for a file. The SVG loads into the preview area immediately.

### Copy to Clipboard

Once an SVG loads in the preview, click **Copy to Clipboard**. The SVG moves onto the clipboard in a format Keynote recognizes, then paste into Keynote with **Cmd+V**.

When vector artwork comes from Illustrator, Affinity Designer, Figma, or another design tool via Copy, switch to KeyJig and the SVG appears in the preview automatically (see [Automatic Clipboard Detection](#automatic-clipboard-detection)). Then click **Copy to Clipboard**.

### Place in Keynote

Click **Place in Keynote** to insert the SVG directly onto the current slide. Keynote must be running with a presentation open.

The first time this feature runs, macOS prompts for Accessibility access. Approve access in **System Settings > Privacy & Security > Accessibility**, then click the button again. Clipboard contents remain unchanged around the transfer.

After insertion, select the object in Keynote and use **Format > Shapes and Lines > Break Apart** to make it editable.

### PDF Fallback

If an SVG does not render correctly in Keynote, click **PDF Fallback** to convert it to PDF using Inkscape. This requires an Inkscape installation. The result moves onto the clipboard for pasting into Keynote.

---

## Automatic Clipboard Detection

KeyJig watches the clipboard and automatically loads any SVG it finds; no button press is required. Detection runs when:

- The app launches
- Focus returns to KeyJig from another app
- The popover or a floating window opens

Detection remains silent and non-destructive: clipboard content never changes. When SVG content appears, it shows up in the preview, ready to drag or copy.

---

## Drag and Drop

The SVG preview area acts as a drag source. To import into Keynote:

1. Load an SVG (from file, clipboard, or auto-detection).
2. Click and drag anywhere on the preview area.
3. Drop it onto a Keynote slide.

Dragging uses native macOS drag-and-drop, so standard system visual feedback appears during the drag. The clipboard does not change during the drag and remains exactly as before.

The preview can also move via drag into any other app that accepts SVG or file drops (Preview, Sketch, Figma, web browsers, etc.).

---

## Troubleshooting

**PDF Fallback shows "Inkscape not found"**  
Install Inkscape from [inkscape.org](https://inkscape.org/), then restart KeyJig.

**SVG does not look right in Keynote**  
Use the PDF Fallback option. If the issue persists, simplify the SVG in the design tool; complex effects and filters sometimes fall outside Keynote’s supported feature set.

**Auto-detection did not pick up the SVG**  
Not all apps export SVG to the clipboard in a recognized format. Use **Open SVG File…** to load directly from disk instead.

**Preview does not appear after dragging a file in**  
Confirm the file is a valid SVG by opening it in a browser. If it appears broken there too, the file itself may be malformed.

**Popover does not appear when clicking the menu bar icon**  
Use **File > Show Menubar Panel** from the menu bar as an alternative. If the problem persists, check Activity Monitor to confirm the app is running and restart if needed.

**Floating window size is not remembered after relaunch**  
Keep the window fully within screen bounds when closing it. Avoid closing the app with Force Quit, which can prevent the saved state from saving correctly.

---

*Requires macOS 11.3 or later. Inkscape is optional and only needed for the PDF Fallback feature.*