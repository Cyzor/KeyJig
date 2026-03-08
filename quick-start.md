# Vector Importer Quick Start Guide

## What is Vector Importer?

Vector Importer is a macOS utility that helps you convert and import vector graphics (SVG files) into Keynote presentations. It bridges the gap between design tools and Keynote by handling format conversions and clipboard management.

## Installation

1. Build the app using Xcode
2. Run the application
3. The app icon appears in your menu bar

## Two Ways to Use

### Mode 1: Menu Bar Popover (Quick & Minimal)

**Perfect for:** Quick imports while working in other apps

**How to use:**
1. Click the Vector Importer icon in the menu bar
2. A popover window appears below the icon
3. Import your SVG using one of the buttons
4. Click elsewhere or click the menu bar icon again to close

**Keyboard shortcut:**
- `Cmd+N` - Show/toggle the popover panel

---

### Mode 2: Floating Window (Full-Featured)

**Perfect for:** Working with multiple SVGs, organizing your workspace

**How to open:**
1. Use **File > New Floating Window** from the menu bar
2. Or press `Cmd+Shift+N`
3. Or click the app icon in the Dock when it's running

**Features:**
- Draggable and resizable window
- Can have multiple windows open at once
- Full menu bar access
- Window position is remembered

---

## Main Features

### Open SVG File
- **Menu:** File > Open SVG...
- **Button:** "Open SVG File..." in the interface
- Lets you browse for and load an SVG file
- Displays a preview of the SVG in the interface

### Bridge Clipboard
- **Button:** "Bridge Clipboard to Keynote"
- Converts clipboard content (from design apps) to SVG format
- Automatically copies the result to clipboard
- Ready to paste into Keynote with Cmd+V

### Copy Preview
- **Button:** "Copy Preview"
- Copies the current SVG preview to clipboard
- Useful if you've loaded a file and want to paste it into Keynote
- Switch to Keynote and paste with Cmd+V

### PDF Fallback
- **Button:** "PDF Fallback"
- Converts the SVG to PDF format using Inkscape
- Use this if Keynote isn't handling your SVG properly
- Requires Inkscape to be installed

---

## Workflow Examples

### Quick Import Workflow
```
1. Click menu bar icon to show popover
2. Click "Bridge Clipboard to Keynote"
3. Switch to Keynote
4. Paste with Cmd+V
5. Done! Click menu bar icon to hide popover
```

### File Import Workflow
```
1. Click "Open SVG File..."
2. Browse to your SVG file and select it
3. Preview appears in the interface
4. Click "Copy Preview"
5. Switch to Keynote and paste
```

### Multi-File Workspace
```
1. Press Cmd+Shift+N to open floating window
2. Keep it visible while working in design app
3. Load different SVG files as needed
4. Import multiple files into Keynote
5. Window stays open until you close it
```

---

## Menu Items

### File Menu
- **Show Panel** - Toggle the menu bar popover
- **New Floating Window** - Open a new standalone window (Cmd+Shift+N)
- **Open SVG...** - Browse for SVG files to import (Cmd+O)
- **Close** - Close the current window (Cmd+W)

### Edit Menu
- Standard editing options (Undo, Redo, Cut, Copy, Paste)

### Help Menu
- **VectorImporter Help** - Display help information

### App Menu
- **About VectorImporter** - Shows app version and copyright
- **Preferences...** - App preferences (placeholder for future use)
- **Hide/Show** - Hide or show the application
- **Quit** - Exit the application (Cmd+Q)

---

## Tips & Tricks

### Keyboard Shortcuts
- `Cmd+N` - Show/hide the menu bar popover
- `Cmd+Shift+N` - Open a new floating window
- `Cmd+O` - Open SVG file dialog
- `Cmd+Q` - Quit the application
- `Cmd+W` - Close current window

### Status Messages
Watch the status area in the interface for feedback:
- "Ready to bridge vectors" - App is ready
- "Loaded: filename.svg" - File successfully loaded
- "Bridged! Switch to Keynote and Paste (⌘V)." - SVG is ready to paste
- "Preview copied for Keynote." - SVG copied to clipboard
- "Inkscape not found" - PDF fallback requires Inkscape installation

### Working with Design Tools
Vector Importer works best with:
- Adobe Illustrator
- Affinity Designer
- Sketch
- Figma
- Any app that can copy SVG to clipboard

Simply copy your vector graphic, then use "Bridge Clipboard to Keynote" in Vector Importer.

### Multiple Windows
- Open several floating windows to work with multiple SVGs simultaneously
- Each window maintains its own SVG state
- All windows share access to file operations
- Close individual windows without affecting others

---

## Troubleshooting

### PDF Fallback isn't working
- **Issue:** "Inkscape not found" message
- **Solution:** Install Inkscape from https://inkscape.org/
- After installation, restart Vector Importer

### SVG doesn't look right in Keynote
- **Solution 1:** Try the "PDF Fallback" option (requires Inkscape)
- **Solution 2:** Check if the SVG is using special effects not supported by Keynote
- **Solution 3:** Edit the SVG in your design tool to simplify it

### Popover doesn't appear
- **Issue:** Clicking menu bar icon doesn't show the popover
- **Solution:** Use File > Show Panel from the menu
- Check that the app hasn't crashed (look in Activity Monitor)

### Can't find the app
- The app lives in your menu bar (top right of your screen)
- Look for the Vector Importer icon among other menu bar apps
- If not visible, relaunch the application

---

## Getting Help

### About Dialog
Click **About VectorImporter** in the app menu for version and copyright information.

### Help
Click **Help** in the menu bar to see detailed help information about the app.

---

## Understanding Modes

| Feature | Menu Bar Popover | Floating Window |
|---------|-------------------|-----------------|
| Always visible | No | Yes |
| Click to toggle | Yes | Click File menu |
| Persistent | No (closes automatically) | Yes |
| Multiple instances | Just one | Many |
| Dock icon | No | Yes |
| Position memory | N/A | Yes |
| Resizable | No | Yes |
| Minimizable | No | Yes |

---

## Compatibility

- **macOS:** 10.15 or later
- **Requires:** Xcode, SVGWebView framework
- **Optional:** Inkscape (for PDF fallback feature)

---

## Keyboard Accessibility

All menu items and buttons are keyboard accessible:
- Use `Tab` to navigate between buttons
- Use `Space` or `Enter` to activate buttons
- Use standard menu shortcuts (Cmd+O, Cmd+Q, etc.)
- Press `?` in the Help menu for help information

---

## Tips for Best Results

1. **Simple SVGs work best** - Complex SVGs with many effects may not render perfectly in Keynote
2. **Test the preview** - Always check the preview before importing into Keynote
3. **Use PDF fallback for complex files** - If the SVG doesn't look right, try the PDF option
4. **Keep files organized** - Use multiple floating windows to organize different projects
5. **Check status messages** - The status area tells you what the app is doing

---

**Happy importing!** 🎨📊

For more detailed technical information, see `DUAL_MODE_IMPLEMENTATION.md`.