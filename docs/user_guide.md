# KeyJig User Guide

## Overview

KeyJig is a macOS utility that bridges vector graphics into Apple Keynote. It handles format conversion, clipboard management, and two-way transfer between your design tools and Keynote.

---

## Installation

1. Build the app in Xcode and run it.
2. The KeyJig icon appears in the menu bar.
3. Optionally install [Inkscape](https://inkscape.org/) to enable conversion of PDF and `.ai` files.

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

### Open a File

Use **File > Open SVG File… (⌘O)** to browse for an SVG, PDF, or `.ai` file. SVG files load immediately; PDF and `.ai` files are converted via Inkscape before loading.

### Drag and Drop

Drag an SVG file directly onto the preview area. KeyJig accepts drops from Finder, other apps, and web browsers.

### Automatic Clipboard Detection

KeyJig watches the clipboard and automatically loads any SVG it finds — no button press required. Detection runs when:

- The app launches
- Focus returns to KeyJig from another app
- The popover or a floating window opens

Detection is silent and non-destructive: clipboard contents never change. When SVG content appears, it shows up in the preview, ready to drag or copy.

---

## Sending to Keynote

### Copy to Clipboard

Click **Copy to Clipboard** (⌘⇧C) to encode the loaded SVG in a format Keynote recognizes. Switch to Keynote and paste with **⌘V**, then select the object and use **Format > Shapes and Lines > Break Apart** to edit individual paths.

This works with SVGs loaded from any source — file, drag, or clipboard detection.

### Place in Keynote

Click **Place in Keynote** to insert the SVG directly onto the current slide without touching the clipboard. Keynote must be running with a presentation open.

The first time this runs, macOS prompts for Accessibility access. Approve it in **System Settings > Privacy & Security > Accessibility**, then click the button again.

After insertion, select the object in Keynote and use **Format > Shapes and Lines > Break Apart** to make it editable.

---

## Pulling from Keynote

### Pull from Keynote

Click **Pull from Keynote** to capture the current Keynote slide as a PDF and load it into the preview well. KeyJig uses GUI scripting to copy the slide, falling back to a document export if that fails. Keynote briefly comes to the front during the operation.

Once the PDF loads, drag the preview directly into Affinity Designer, Illustrator, Figma, or any app that accepts PDF drops.

### Import Selection (Option modifier)

Hold **Option** while clicking the pull button to crop the result to the currently selected objects on the slide. The button label changes to **Import Selection from Keynote** while Option is held. This requires objects to be selected in Keynote before clicking.

---

## Drag and Drop (Preview Well)

The preview area acts as both a drag source and a drop target.

**Outbound drag** — Click and drag the loaded SVG or PDF preview to any compatible app: Keynote, Affinity Designer, Illustrator, Figma, etc. The clipboard is not modified during the drag.

**Inbound drop** — Drop an SVG file onto the preview area to replace the current contents. If a PDF is loaded and you drop an SVG, the well switches to SVG mode automatically.

**Trash button** — Click the trash icon in the lower-right of the preview well to clear the current content (same as right-click > Clear).

---

## Troubleshooting

**"Open SVG File…" does not appear as a button**  
The file-open button was removed. Use **File > Open SVG File… (⌘O)** from the menu bar instead.

**Inkscape not found**  
Install Inkscape from [inkscape.org](https://inkscape.org/), then restart KeyJig. Without Inkscape, PDF and `.ai` conversion is unavailable, but SVG workflows work without it.

**SVG does not look right in Keynote**  
Inkscape can produce a more Keynote-compatible result. Install it, then re-open or re-drop the file; KeyJig will use Inkscape for the conversion automatically.

**Auto-detection did not pick up the SVG**  
Not all apps export SVG to the clipboard in a recognized format. Use **File > Open SVG File… (⌘O)** to load directly from disk.

**Preview does not appear after dropping a file**  
Confirm the file is a valid SVG by opening it in a browser. If it appears broken there too, the file may be malformed.

**Pull from Keynote shows an error about Accessibility**  
Grant KeyJig Accessibility permission in **System Settings > Privacy & Security > Accessibility**, then try again. The GUI scripting path needs this; the export fallback does not.

**Popover does not appear when clicking the menu bar icon**  
Use **File > Show Menubar Panel** from the menu bar as an alternative. If the problem persists, check Activity Monitor to confirm the app is running and restart if needed.

**Floating window size is not remembered after relaunch**  
Keep the window fully within screen bounds when closing it. Avoid closing with Force Quit, which can prevent the saved state from writing correctly.

---

*Requires macOS 11.3 or later. Inkscape is optional and only needed for PDF and .ai conversion.*
