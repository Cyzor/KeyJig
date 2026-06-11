# KeyJig User Guide

## Overview

KeyJig is a macOS menu bar utility that moves vector graphics into Apple Keynote as editable paths, and extracts vector content back out as PDF.

---

## Installation

1. Download the latest build from [Releases](https://github.com/Cyzor/KeyJig/releases/latest), or build in Xcode and run.
2. KeyJig appears as an icon in the menu bar.
3. Grant permissions when prompted — Accessibility for Place in Keynote (⌘D), Automation for pulling slides and selections. Both live in **System Settings → Privacy & Security**.
4. Optionally install [Inkscape](https://inkscape.org/) to open PDF and `.ai` files (`brew install inkscape`).

---

## Using KeyJig

### Menu Bar

Click the KeyJig icon in the menu bar to open a compact popover. Click outside to dismiss it. Drag artwork directly onto the icon to load it without opening the popover.

### Main Window

**File → Show Window** or **File → New Viewer** (⌘⇧N) opens a persistent, resizable window. Multiple windows can be open at once; each holds independent content. Position and size persist between sessions.

---

## Importing Graphics

### Open a File

**File → Open SVG File… (⌘O)** opens an SVG, PDF, or `.ai` file. PDF and `.ai` files convert via Inkscape first.

### Drag and Drop

Drag a file onto the preview area or onto the menu bar icon. KeyJig accepts drops from Finder, other apps, and web browsers.

### Clipboard Auto-Detection

KeyJig checks the clipboard for SVG content when it launches, comes to the foreground, or a window or popover opens. When it finds something, it loads automatically — no button press needed. The clipboard is never modified.

Not all apps write SVG to the clipboard in a recognized format. If auto-detection misses artwork, use **File → Open SVG File… (⌘O)** instead.

---

## Sending to Keynote

### Copy for Keynote

Press **⌘K** (or right-click the preview) to encode the loaded graphic in a Keynote-compatible format and copy it to the clipboard. Switch to Keynote, paste with **⌘V**, then use **Format → Shapes and Lines → Break Apart** to edit individual paths.

### Place in Keynote

Press **⌘D** to drop the graphic directly onto the current Keynote slide. Keynote must be open with a presentation loaded.

Requires Accessibility permission — grant it in **System Settings → Privacy & Security → Accessibility**, then try again. After insertion, use **Format → Shapes and Lines → Break Apart** to make the paths editable.

---

## Pulling from Keynote

Hold **Option** to reveal the pull buttons. Both require Automation permission; macOS prompts on first use.

### Convert Keynote Slide to PDF (⌘R)

Exports the current Keynote slide as a vector PDF and loads it into the preview. No selection needed. Drag the result into Affinity Designer, Illustrator, Figma, or any app that accepts PDF.

### Convert Keynote Clipboard to PDF (⌘E)

Select one or more objects in Keynote and copy them (**⌘C**), then press **⌘E** in KeyJig. The result contains only the selected objects — non-contiguous selections included. Without a prior copy, KeyJig falls back to the bounding rectangle of the current selection.

---

## Preview Well

**Outbound drag** — drag the preview to any compatible app: Keynote, Affinity Designer, Illustrator, Figma, etc. The clipboard is not modified.

**Inbound drop** — drop an SVG file onto the preview to replace the current content.

**Clear** — right-click the preview and choose **Clear**, press **Delete** (or **⌘Delete**), or use **Edit → Clear**. A clear is never final: **⌘Z** undoes it, and **⇧⌘Z** re-clears.

**History** — KeyJig remembers the last few graphics loaded in each window (up to 10). **⌘[** steps back through them and **⌘]** steps forward, browser-style — handy when iterating on artwork or comparing pulled slides. History is per window and discarded when the window closes.

---

## Troubleshooting

**PDF or .ai file doesn't open**  
Install Inkscape from [inkscape.org](https://inkscape.org/). Without it, only SVG files load.

**SVG looks wrong in Keynote**  
Install Inkscape. When present, KeyJig routes the conversion through it for better compatibility.

**Clipboard detection missed the artwork**  
Not all apps write SVG to the clipboard in a recognized format. Use **File → Open SVG File… (⌘O)** to load from disk instead.

**Preview doesn't appear after dropping a file**  
Open the file in a browser to confirm it's valid. If it looks broken there, the file is malformed.

**Place in Keynote does nothing**  
Grant Accessibility permission in **System Settings → Privacy & Security → Accessibility**, then try again. Placing SVG also requires Keynote 13.1 or later (the version that added native SVG import); older versions are blocked with a message.

**Pull buttons aren't visible**  
Hold **Option** to reveal them. If they're grayed out, grant Automation permission in **System Settings → Privacy & Security → Automation**.

**Popover doesn't open**  
Use **File → Show Menubar Panel** as an alternative. If the problem persists, check Activity Monitor and restart KeyJig.
