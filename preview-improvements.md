# Preview and Drag Improvements

## Overview

Vector Importer now uses native macOS drag-and-drop APIs for a polished, professional appearance. The SVG preview fills the entire well region, providing maximum visual representation of the content being dragged.

## Native Drag and Drop

### Previous Approach
- Used SwiftUI's `.onDrag` modifier with custom preview
- Generic placeholder preview that didn't represent content
- Awkward bordered rectangle
- Limited visual feedback

### Current Approach
- Uses native NSView-based drag and drop APIs
- Leverages macOS's built-in drag feedback system
- Automatic scaling and animation
- Professional appearance matching system standards

### How It Works

The drag operation is now handled through native NSView methods:

```swift
override func mouseDragged(with event: NSEvent) {
    let pasteboard = NSPasteboard(name: .drag)
    let tempURL = getTempSVGURL()
    
    do {
        try svgString.write(to: tempURL, atomically: true, encoding: .utf8)
        pasteboard.clearContents()
        pasteboard.writeObjects([tempURL as NSURL])
        
        let draggingItem = NSDraggingItem(pasteboardWriter: tempURL as NSURL)
        draggingItem.setDraggingFrame(bounds, contents: image)
        
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    } catch {
        NSLog("Error writing temp SVG: \(error)")
    }
}
```

### Drag Feedback

When dragging, macOS automatically provides:
- Smooth fade animation
- Proper drag cursor feedback
- System-level visual feedback
- Professional appearance that matches other macOS apps

## Preview Fill Behavior

### Layout Improvements

**Previous:**
- Preview constrained to fit within padding
- Square-ish aspect ratio limiting
- Wasted space around content

**Current:**
- Preview fills entire well region
- Proportional scaling to fit container
- No wasted whitespace
- Content-driven layout

### SVG Rendering

The preview now uses a custom HTML rendering approach:

```html
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <style>
        body { margin: 0; padding: 0; display: flex; 
               align-items: center; justify-content: center; 
               background: transparent; overflow: hidden; }
        svg { width: 100%; height: 100%; object-fit: contain; }
    </style>
</head>
<body>
    {SVG content}
</body>
</html>
```

This ensures:
- SVG fills available space
- Aspect ratio maintained
- Centered rendering
- No clipping at any size
- Works with any SVG dimensions

## Implementation Details

### SVGDraggableView Class

A custom NSView subclass that handles:
- SVG rendering via WKWebView
- Native drag and drop
- Proper frame management
- Dynamic SVG updates

### Key Methods

**setupView()**
- Configures layer properties
- Sets up WebView constraints
- Registers drag types

**loadSVG()**
- Creates HTML wrapper
- Loads SVG into WebView
- Ensures proper scaling

**mouseDragged(with:)**
- Intercepts drag events
- Writes SVG to temp file
- Initiates dragging session
- Provides native feedback

**updateSVG(_:)**
- Updates SVG content
- Reloads WebView
- No need to recreate view

### SVGPreviewView

SwiftUI wrapper that:
- Bridges NSView to SwiftUI
- Maintains state synchronization
- Handles content updates
- Provides proper layout

## User Experience

### In the Popup

1. Click menu bar icon
2. SVG preview fills entire popover area
3. Click and drag the preview
4. Native macOS drag feedback appears
5. Drop into Keynote
6. File is imported with proper feedback

### In Floating Windows

1. Open floating window (Cmd+Shift+N)
2. Load SVG - preview fills entire area
3. Resize window - preview scales proportionally
4. Drag preview to Keynote
5. Native feedback during drag operation
6. Perfect visual representation

### Popover vs Floating Window

**Popover (480×680):**
- Quick access from menu bar
- SVG preview fills available space
- Professional drag feedback
- Transient behavior

**Floating Window:**
- Resizable (320×900 width, 380×1200 height)
- SVG scales with window
- Full-featured drag and drop
- Persistent until closed

## Technical Advantages

### Native APIs
- Uses NSPasteboard for drag content
- Implements NSDraggingSource protocol
- Follows macOS drag and drop conventions
- System handles visual feedback automatically

### Performance
- WKWebView renders efficiently
- Native drag operations are optimized
- Minimal memory overhead
- Smooth scaling and rendering

### Compatibility
- Works with any SVG format
- Handles complex SVGs
- No format conversion needed
- Maintains vector quality

## Visual Quality

### What You See

When dragging, users see:
- Smooth fade animation from original position
- System drag cursor feedback
- Visual indication of drop validity
- Professional appearance

When previewing:
- Full SVG content visible
- Proper aspect ratio
- Centered in available space
- Clear representation of what will be imported

## Code Structure

### File Organization

```
ContentView.swift
├── ContentView (SwiftUI main view)
├── SVGPreviewView (SwiftUI NSViewRepresentable)
├── SVGDraggableView (NSView subclass)
│   ├── setupView()
│   ├── loadSVG()
│   ├── updateSVG()
│   └── mouseDragged(with:)
└── Extensions
    ├── NSDraggingSource
    └── Navigation delegate
```

### Dependencies
- AppKit (for NSView, NSDragging)
- WebKit (for WKWebView)
- SwiftUI (for integration)

## Testing Recommendations

### Drag and Drop
- [ ] Load SVG - preview fills area
- [ ] Drag from popover - smooth animation
- [ ] Drag from floating window - feedback works
- [ ] Drop in Keynote - file imports correctly
- [ ] Multiple SVGs - each drags independently

### Preview Scaling
- [ ] Popover shows full SVG
- [ ] Floating window: small SVG - fills area
- [ ] Floating window: large SVG - fits proportionally
- [ ] Resize window - preview scales smoothly
- [ ] All SVG types display correctly

### User Feedback
- [ ] Drag appears smooth and responsive
- [ ] System cursor shows drop validity
- [ ] No lag during drag operations
- [ ] Preview matches actual content

## Known Characteristics

### Drag Behavior
- Uses system's native drag animation
- Automatically handles cursor feedback
- Drop target validation is automatic
- File is written to temp location during drag

### Preview Rendering
- SVG rendered in WKWebView with HTML wrapper
- Aspect ratio maintained automatically
- Centered and scaled via CSS
- No manual aspect ratio calculation needed

## Future Enhancements

Potential improvements:
1. Custom drag image with content preview
2. Drag preview zoom animation
3. Multiple file drag support
4. Drag progress indication
5. Custom drop zones in floating windows

## Summary

Vector Importer now provides:

✓ Native macOS drag and drop experience
✓ Professional visual feedback during drag
✓ Preview fills entire well region
✓ Proper SVG scaling at any size
✓ System-level drag animation and feedback
✓ Seamless integration with macOS
✓ Clean, efficient implementation

The improvements make Vector Importer feel like a native macOS application, with drag and drop that matches user expectations and system conventions.