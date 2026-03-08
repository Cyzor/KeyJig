# Resizable Windows Feature

## Overview

Vector Importer now supports resizable windows with flexible preview scaling. The thumbnail preview (the draggable well) automatically expands and scales to fit the window, providing a better view of your SVG content regardless of window size.

## Window Sizing

### Size Constraints

**Floating Windows:**
- **Minimum:** 320 × 380 pixels
- **Default:** 400 × 520 pixels  
- **Maximum:** 900 × 1200 pixels

These constraints ensure:
- Windows never become too small to use effectively
- Reasonable maximum prevents excessive resource usage
- Default size provides good balance of preview and controls

**Menu Bar Popover:**
- Fixed size: 400 × 520 pixels
- Non-resizable (typical popover behavior)

### Resizing Methods

You can resize floating windows using:
1. **Corner handles** - Click and drag from any corner
2. **Edge handles** - Click and drag from top, bottom, left, or right edge
3. **Keyboard shortcuts** - Cmd+Ctrl+F to toggle full screen (if enabled)
4. **Window menu** - File > Zoom (or double-click title bar)

## Preview Scaling

### Automatic Fit

The SVG preview now:
- Scales proportionally to fit the available space
- Never crops or distorts the image
- Maintains aspect ratio at any window size
- Uses `.scaledToFit()` modifier for proper scaling

### Preview Expansion

The preview area:
- Grows when you enlarge the window
- Shrinks when you make the window smaller
- Always maintains minimum of 100 pixels height
- Takes up remaining space after controls/buttons

### Layout Flow

```
┌─────────────────────────────┐
│     Vector Importer          │ ← Title bar
├─────────────────────────────┤
│                             │
│    SVG Preview              │ ← Expands/shrinks with window
│    (Draggable Well)         │
│                             │
├─────────────────────────────┤
│  Ready to bridge vectors    │ ← Status (fixed height)
├─────────────────────────────┤
│  [Open SVG File...]         │
│  [Bridge Clipboard...]      │ ← Action buttons (fixed height)
│  [Copy Preview] [PDF...]    │
├─────────────────────────────┤
│ VectorImporter              │ ← Footer (fixed height)
└─────────────────────────────┘
```

## Usage Examples

### Compact Workspace
1. Keep window at minimum size (320 × 380) when space is limited
2. Focus on button interactions rather than preview
3. Preview shows small but complete SVG
4. Good for tiled window layouts

### Optimal Preview
1. Resize to ~500 × 700 pixels
2. Large preview area makes details visible
3. Still compact enough for secondary workspace
4. Good balance of preview and controls

### Full Workspace
1. Resize to ~700 × 1000+ pixels
2. Maximum preview visibility
3. Professional editing workspace
4. Detailed SVG inspection before import

### Multiple Windows
1. Open several floating windows (Cmd+Shift+N)
2. Position them side-by-side
3. Resize each for optimal viewing
4. Work with multiple SVGs simultaneously

## Practical Workflows

### Detailed Vector Inspection
```
1. Open floating window
2. Enlarge to ~700 × 1000
3. Load complex SVG
4. Preview scales to show all details
5. Drag to Keynote when satisfied
```

### Batch Processing
```
1. Open two floating windows side-by-side
2. Resize each to ~450 × 600
3. Load different SVGs in each
4. Compare previews before importing
5. Drag each to appropriate slide
```

### Quick Import
```
1. Keep window at minimum size
2. Focus on clipboard bridging
3. Drag small preview to Keynote
4. Move to next file
```

## Technical Details

### Layout Structure

**ContentView changes:**
- Removed fixed `.frame(width: 380, height: 480)`
- Preview now uses `.frame(minHeight: 100, maxHeight: .infinity)`
- Status area fixed at 50pt height
- Buttons fixed at natural height
- Footer fixed at ~50pt height
- Spacer between buttons and footer removed

**SVGWebView scaling:**
- Uses `.scaledToFit()` modifier
- Maintains aspect ratio
- Centers content
- Pads 10pt inside preview area

### Window Configuration

**MainWindowController:**
```swift
window.minSize = NSSize(width: 320, height: 380)
window.maxSize = NSSize(width: 900, height: 1200)
```

**Frame Auto-Save:**
- Window position and size saved automatically
- Restored when window reopens
- Each floating window remembers its size independently

## Responsive Behavior

### What Scales
✓ SVG preview area
✓ Preview padding
✓ Overall window layout
✓ Preview aspect ratio (maintained)

### What's Fixed
✗ Status text height (50pt)
✗ Button heights (natural sizing)
✗ Footer height (~50pt)
✗ Margins and padding (except preview)

## Accessibility

### Keyboard Navigation
- Tab through buttons normally
- Window can be resized with keyboard shortcuts
- Preview remains draggable at any size
- Status messages visible at all sizes

### Visual Feedback
- Standard macOS resize cursors at window edges
- Clear preview scaling feedback
- Minimum size prevents unusable state

## Performance Considerations

### Rendering
- SVG rendered at preview size (no performance penalty)
- Scaling happens in UI layer (efficient)
- No re-rendering on resize (smooth operation)

### Memory
- Single ContentView instance per window
- No duplication of SVG data
- Shared AppState across windows

## Troubleshooting

### Preview Not Scaling
**Issue:** Preview doesn't fill available space when window is enlarged

**Solutions:**
1. Try resizing in other direction
2. Close and reopen window
3. Load different SVG file
4. Check that SVG is valid

### Preview Appears Clipped
**Issue:** SVG looks cut off even in large window

**Solutions:**
1. This shouldn't happen - if it does, please report
2. Check original SVG has no viewport issues
3. Try PDF Fallback option
4. Inspect SVG in browser to verify

### Window Won't Resize
**Issue:** Resize handles not responding

**Solutions:**
1. Click title bar and drag (alternative resize method)
2. Try File > Zoom menu item
3. Close and reopen window
4. Restart app

### Window Size Not Remembered
**Issue:** Window position/size resets after closing

**Solutions:**
1. Make sure window is fully within screen bounds
2. Avoid extreme sizes (near minimum/maximum)
3. Close window normally (don't force quit)
4. Check that Derived Data folder wasn't cleared

## Best Practices

1. **For Detail Work:** Use larger window (700+ pixels)
2. **For Quick Work:** Use compact window (320 × 380)
3. **For Comparisons:** Multiple windows side-by-side
4. **For Inspection:** Expand to see all SVG details before dragging

## Future Enhancements

Potential improvements:
1. Customizable size presets (compact, standard, large)
2. Snap-to-grid option for consistent sizing
3. Window arrangement management (save/restore layouts)
4. SVG zoom controls (independent of window size)
5. Full-screen mode option
6. Dockable preview panel option

## Limits and Constraints

### Why These Limits?

**Minimum (320 × 380):**
- Ensures all buttons remain visible and clickable
- Prevents unusable interface state
- Maintains readable text

**Maximum (900 × 1200):**
- Prevents excessive memory usage
- Ensures reasonable performance
- Fits within typical monitor arrangements
- Avoids empty whitespace at very large sizes

### Increasing Limits

To adjust these limits, edit MainWindowController in AppDelegate.swift:

```swift
window.minSize = NSSize(width: 300, height: 360)  // Smaller
window.maxSize = NSSize(width: 1200, height: 1600)  // Larger
```

## Summary

The resizable windows feature provides:
- ✓ Flexible interface for different workflows
- ✓ Responsive preview that scales with window
- ✓ Maintains SVG proportions automatically
- ✓ Reasonable size constraints
- ✓ Position/size persistence across launches
- ✓ Works seamlessly with drag-and-drop

This enhancement makes Vector Importer adaptable to various working styles and screen sizes while keeping the interface clean and functional at any dimension.