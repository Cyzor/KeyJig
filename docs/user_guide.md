# KeyJig User Guide

## Overview

KeyJig is a macOS menu bar utility that makes it easy to bring SVG vector graphics into Keynote. It handles format conversion and clipboard management so you can go from your design tool to your presentation in just a few steps.

---

## Installation

1. Build the app in Xcode and run it.
2. The KeyJig icon appears in your menu bar.
3. Optionally install [Inkscape](https://inkscape.org/) to enable the PDF fallback feature.

---

## Using KeyJig

The app has two modes. Both offer the same core features — choose whichever fits your workflow.

### Menu Bar Popover

Click the KeyJig icon in the menu bar to open a compact popover. Click the icon again, or click anywhere outside the popover, to dismiss it.

Best for quick, one-off imports while you're focused in another app.

### Floating Window

Open a persistent, resizable window that stays on screen while you work.

- **File > New Viewer** or **Cmd+Shift+N** opens a new window.
- You can open multiple floating windows at the same time.
- Each window can be moved, resized, and minimized independently.
- Window position and size are remembered between sessions.

**Floating window size range:** 320×520 px (minimum) to 900×1200 px (maximum). The SVG preview scales automatically as you resize.

Best for working with multiple SVGs, comparing files side by side, or keeping KeyJig visible on a secondary display.

---

## Importing SVGs

### Open an SVG File

Click **Open SVG File…** (or use **File > Open SVG… / Cmd+O**) to browse for a file. The SVG loads into the preview area immediately.

### Copy to Clipboard

Once an SVG is loaded in the preview, click **Copy to Clipboard**. The SVG is placed on your clipboard in a format Keynote recognizes — switch to Keynote and paste with **Cmd+V**.

If you've just copied vector artwork from Illustrator, Affinity Designer, Figma, or another design tool, switch to KeyJig and the SVG will appear in the preview automatically (see [Automatic Clipboard Detection](#automatic-clipboard-detection)). Then click **Copy to Clipboard**.

### PDF Fallback

If an SVG doesn't render correctly in Keynote, click **PDF Fallback** to convert it to PDF using Inkscape. This requires Inkscape to be installed. The result is placed on your clipboard for pasting into Keynote.

---

## Automatic Clipboard Detection

KeyJig watches your clipboard and automatically loads any SVG it finds — no button press needed. Detection happens when:

- The app launches
- You switch back to KeyJig from another app
- The popover or a floating window opens

The detection is silent and non-destructive: your clipboard content is never modified. If SVG content is found, it simply appears in the preview, ready to drag or copy.

---

## Drag and Drop

The SVG preview area is a drag source. To import into Keynote:

1. Load an SVG (from file, clipboard, or auto-detection).
2. Click and drag anywhere on the preview area.
3. Drop it onto your Keynote slide.

Dragging uses native macOS drag-and-drop, so you get standard system visual feedback. Your clipboard is not modified during the drag — it stays exactly as you left it.

You can also drag the preview into any other app that accepts SVG or file drops (Preview, Sketch, Figma, web browsers, etc.).

---

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| **Cmd+N** | Show / hide the menu bar popover |
| **Cmd+Shift+N** | Open a new floating window |
| **Cmd+O** | Open SVG file |
| **Cmd+W** | Close current window |
| **Cmd+Q** | Quit KeyJig |

---

## Troubleshooting

**PDF Fallback shows "Inkscape not found"**
Install Inkscape from [inkscape.org](https://inkscape.org/), then restart KeyJig.

**SVG doesn't look right in Keynote**
Try the PDF Fallback option. If the issue persists, simplify the SVG in your design tool — complex effects and filters are sometimes unsupported by Keynote.

**Auto-detection didn't pick up my SVG**
Not all apps export SVG to the clipboard in a recognized format. Use **Open SVG File…** to load directly from disk instead.

**Preview doesn't appear after dragging a file in**
Confirm the file is a valid SVG by opening it in a browser. If it appears broken there too, the file itself may be malformed.

**Popover doesn't appear when clicking the menu bar icon**
Use **File > Show Menubar Panel** from the menu bar as an alternative. If the problem persists, check Activity Monitor to confirm the app is running and restart if needed.

**Floating window size isn't remembered after relaunch**
Make sure the window is fully within your screen bounds when you close it. Avoid closing the app with Force Quit, which can prevent the saved state from being written.

---

*Requires macOS 11.3 or later. Inkscape is optional and only needed for the PDF Fallback feature.*
