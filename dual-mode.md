# Vector Importer: Dual-Mode Implementation Guide

## Overview

Vector Importer has been updated to support both **menu bar popover mode** and **floating window mode**. The app now provides the best of both worlds:
- A compact, traditional menu bar popover for quick access
- Draggable floating windows for users who want a persistent workspace

## Architecture

### Core Components

1. **NSPopover (Menu Bar Mode)**
   - Traditional transient popover anchored to the menu bar icon
   - Click the menu bar icon to show/hide
   - Automatically closes when you click elsewhere
   - This is the default, minimal-footprint mode

2. **MainWindowController (Floating Windows)**
   - Manages standalone NSWindow instances
   - Each floating window is a full application window
   - Can be dragged, resized, minimized, and positioned anywhere
   - Persists on screen until explicitly closed
   - Multiple floating windows can be open simultaneously

3. **AppMenu (Standard macOS Menus)**
   - File Menu: Show Panel, New Floating Window, Open SVG..., Close
   - Edit Menu: Standard edit items
   - Help Menu: VectorImporter Help
   - App Menu: About, Preferences, Hide/Show, Quit
   - All standard keyboard shortcuts supported

## User Experience

### Menu Bar Popover (Default Mode)

**How to use:**
1. Click the Vector Importer icon in the menu bar
2. The popover appears below the icon
3. Use it to import SVGs, bridge clipboard content, etc.
4. Click the menu bar icon again or click elsewhere to hide

**Characteristics:**
- Compact and non-intrusive
- Transient (closes automatically when you click outside)
- Quick access workflow
- Follows standard macOS menu bar utility conventions

### Floating Windows

**How to open:**
1. Click **File > Show Panel** from the menu (when popover is visible)
2. Or click **File > New Floating Window** (Cmd+Shift+N)
3. Or click the Dock icon when app is running

**Characteristics:**
- Full-featured application windows
- Can be moved freely around the screen
- Can be resized and minimized
- Persist until you close them
- Multiple windows can be open at once
- Shows app in the Dock
- All menus and keyboard shortcuts available

### Workflow Examples

**Typical Menu Bar Workflow:**
```
1. Working in design app → Click menu bar icon
2. Vector Importer popover appears
3. Import SVG or bridge clipboard
4. Click elsewhere to dismiss
5. Return to design app
```

**Typical Floating Window Workflow:**
```
1. Click File > New Floating Window
2. Position window on secondary monitor or side of screen
3. Keep window open while working in other apps
4. Drag and drop SVGs or use clipboard bridging
5. Window stays available as needed
```

## Implementation Details

### File Changes

#### `AppDelegate.swift`
Main changes include:

**MainWindowController class:**
- Simple, clean NSWindowController subclass
- Manages individual floating window instances
- Auto-saves window position and size
- Cleans up after itself when closed

**AppDelegate class:**
- `popover`: NSPopover instance for menu bar mode
- `floatingWindows`: Array to track open floating window instances
- `togglePopover()`: Shows/hides the menu bar popover
- `showPanel()`: Convenience method to show popover (File menu item)
- `newFloatingWindow()`: Creates and positions a new floating window
- `applicationShouldTerminateAfterLastWindowClosed()`: Returns false to keep menu bar active

**AppMenu class:**
- Builds standard macOS menu structure
- File menu includes both "Show Panel" and "New Floating Window" options
- All keyboard shortcuts properly configured

#### `ContentView.swift`
- Removed "Quit" button (available in menus)
- Improved spacing
- Code formatting cleanup
- View works identically in popover and floating windows

#### `Info.plist`
- `LSUIElement` = false: Shows app in Dock for floating windows
- Version updated to 1.1
- Window persistence settings configured

### Code Architecture

```
AppDelegate
├── popover (NSPopover) → ContentView
├── statusBarItem (NSStatusItem with menu bar icon)
│   └── togglePopover action on click
├── floatingWindows (Array<MainWindowController>)
│   └── Each contains an NSWindow with ContentView
└── AppMenu (static setup for menu bar)

MainWindowController
├── NSWindow (floating, resizable, movable)
├── NSHostingController wrapping ContentView
└── Frame auto-save for position/size
```

## Key Features

### Popover Mode
✓ Click menu bar icon to toggle visibility
✓ Transient behavior (closes on click outside)
✓ Quick access workflow
✓ Minimal screen footprint
✓ File > Show Panel menu item

### Floating Window Mode
✓ File > New Floating Window menu item
✓ Full window management (resize, minimize, move)
✓ Multiple windows simultaneously
✓ Persistent until closed
✓ Standard macOS window behavior
✓ Shows in Dock
✓ Window position/size remembered across launches

### Menus
✓ File: Show Panel, New Floating Window, Open SVG..., Close
✓ Edit: Standard edit items
✓ Help: Help text
✓ App: About, Preferences, Hide/Show, Quit
✓ All keyboard shortcuts working

## Technical Details

### Window Configuration

**Popover:**
```swift
let popover = NSPopover()
popover.contentSize = NSSize(width: 400, height: 520)
popover.contentViewController = NSHostingController(rootView: contentView)
popover.behavior = .transient  // Closes on outside click
```

**Floating Window:**
```swift
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 400, height: 520),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false
)
window.level = .normal  // Normal window, not floating above others
window.setFrameAutosaveName("VectorImporterFloatingWindow")  // Persist position
```

### State Management

The app maintains:
- Single `popover` instance (reused)
- Array of `floatingWindows` (one per open floating window)
- Shared `AppState` for SVG content (works across all windows)
- When a floating window closes, it removes itself from the array

## Testing Recommendations

### Popover Functionality
- [ ] Click menu bar icon → popover appears below icon
- [ ] Click menu bar icon again → popover hides
- [ ] Click elsewhere → popover closes
- [ ] File > Show Panel works when popover hidden
- [ ] Popover closes when clicking outside

### Floating Window Functionality
- [ ] File > New Floating Window creates window at screen center
- [ ] Window can be dragged to any position
- [ ] Window can be resized (corner and edge handles)
- [ ] Window can be minimized
- [ ] Multiple floating windows can be open
- [ ] Closing floating window doesn't affect popover or menu bar
- [ ] Floating window position is remembered after restart

### Mixed Mode
- [ ] Popover visible + floating window open simultaneously
- [ ] Each window has independent SVG state (via AppState)
- [ ] Menus work in both contexts
- [ ] Dock icon shows when any window is open
- [ ] App continues running with menu bar even if all windows closed

### Core Functionality
- [ ] Open SVG works in popover
- [ ] Open SVG works in floating window
- [ ] Clipboard bridging works in both
- [ ] PDF fallback works in both
- [ ] Drag-and-drop preview works in both
- [ ] Status messages display in both

### Menu Items
- [ ] File > Open SVG... works
- [ ] File > Close closes floating windows
- [ ] File > Show Panel shows popover
- [ ] File > New Floating Window (Cmd+Shift+N) creates window
- [ ] Help > VectorImporter Help displays help
- [ ] About displays about dialog
- [ ] Quit (Cmd+Q) terminates app

## Backward Compatibility

All existing functionality preserved:
- SVG loading and preview
- Clipboard bridging
- PDF fallback conversion
- Drag-and-drop support
- `AppState` singleton
- All keyboard shortcuts
- All utility functions

## Known Limitations

1. Edit menu items (Undo, Redo, Cut, Copy, Paste) are placeholder items
2. Preferences dialog currently shows placeholder text
3. Only one popover exists (can't open multiple popovers from menu bar)
4. Floating windows share the same ContentView template

## Future Enhancements

Potential improvements:
1. Add user preferences for default mode (popover vs. floating window)
2. Keyboard shortcut to open floating window from popover
3. Drag popover to convert to floating window (advanced interaction)
4. Window management: cascading new windows, tiling options
5. Separate preferences dialog with actual settings
6. Popover customization (transparency, size, position memory)
7. Quick actions in menu bar (recent files, recent operations)
8. Context menu on menu bar icon for quick actions

## Summary

Vector Importer now provides both minimal (menu bar popover) and full-featured (floating windows) modes. Users can:
- Use the menu bar icon for quick, transient access
- Open floating windows for persistent workspace access
- Combine both approaches in a single session
- All functionality available in both modes

This dual-mode approach accommodates different workflows and user preferences while maintaining the app's lightweight core functionality.