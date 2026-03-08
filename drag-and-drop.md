# Drag and Drop Implementation

## Overview

Vector Importer supports native macOS drag and drop, allowing users to drag SVG previews directly into Keynote or other applications. The implementation uses NSView-based drag sources for reliable, system-integrated behavior.

## How It Works

### Drag Initiation

When a user clicks and drags on the SVG preview area:

1. The `mouseDown(with:)` method is called in `SVGDraggableView`
2. The SVG content is written to a temporary file
3. A dragging session is created with `beginDraggingSession(with:event:source:)`
4. The file URL is placed on the drag pasteboard
5. macOS takes over with system-level drag feedback

### Visual Feedback

- Users see the standard macOS drag cursor animation
- The dragged item appears as the system default (file icon)
- Drop target validation is automatic (macOS handles this)
- Smooth fade animation follows cursor movement

### Drop Handling

When dragging into Keynote:
1. The SVG file URL is available on the pasteboard
2. Keynote receives the file and imports it
3. The temporary file persists until the drag completes
4. Cleanup happens automatically via system

## Technical Implementation

### SVGDraggableView Class

A custom NSView that manages SVG rendering and dragging:

```swift
class SVGDraggableView: NSView {
    private let svgWebView = WKWebView()
    private var svgString: String = ""
    private let tempURL = getTempSVGURL()
    
    // Initialization and setup...
    
    override func mouseDown(with event: NSEvent) {
        // Write SVG to temp file
        // Create dragging session
        // Place file URL on pasteboard
    }
}
```

### Key Methods

**mouseDown(with:)**
- Intercepts user mouse clicks on the view
- Writes current SVG to temporary file
- Creates and initiates dragging session
- Called automatically when user clicks and holds

**draggingSession(_:sourceOperationMaskFor:)**
- Specifies what drag operations are allowed
- Returns `.copy` to indicate file copying
- Called by macOS during drag operation

**draggingSession(_:endedAt:operation:)**
- Called when drag session completes
- Allows cleanup if needed
- Currently a no-op (system handles cleanup)

### File URL on Pasteboard

```swift
let pasteboard = NSPasteboard(name: .drag)
pasteboard.clearContents()
pasteboard.writeObjects([tempURL as NSURL])
```

The SVG file URL is written to the drag pasteboard, making it available to drop targets like Keynote.

## Integration with SwiftUI

### SVGPreviewView

A SwiftUI wrapper that bridges `SVGDraggableView` into SwiftUI:

```swift
struct SVGPreviewView: NSViewRepresentable {
    let svgString: String
    
    func makeNSView(context: Context) -> SVGDraggableView {
        return SVGDraggableView(svgString: svgString)
    }
    
    func updateNSView(_ nsView: SVGDraggableView, context: Context) {
        nsView.updateSVG(svgString)
    }
}
```

This allows the native NSView drag implementation to work seamlessly within SwiftUI.

## Workflow

### In Menu Bar Popover

1. Click menu bar icon to show popover
2. SVG automatically loads from clipboard
3. Click and drag the preview area
4. Drag the SVG to Keynote
5. Release to import
6. Smooth system feedback throughout

### In Floating Window

1. Open floating window (Cmd+Shift+N)
2. Load SVG from file or clipboard
3. Click and drag anywhere in the preview area
4. Drag to Keynote or other app
5. Release to complete import

### Keyboard and Accessibility

- Click and drag is the primary interaction
- Works with trackpad and mouse
- Standard macOS drag conventions apply
- Accessible via standard drag and drop APIs

## Why This Approach

### Benefits of NSView-Based Drag

**Reliability**
- NSView drag sources are well-established
- Consistent with macOS conventions
- No SwiftUI workarounds needed

**System Integration**
- Uses native NSDraggingSource protocol
- Automatic cursor feedback
- Works with all macOS drop targets

**Simplicity**
- Direct mouseDown interception
- Clear flow: write file → create session → drop
- Minimal state management

**Performance**
- Lightweight implementation
- No unnecessary rendering
- Efficient file writing

## File Handling

### Temporary Files

SVGs are written to the system temp directory:
- Path: `/var/folders/.../T/VectorImporter_bridge.svg`
- Created fresh on each drag
- Cleaned up by system after drop completes
- Reused across multiple drags

### No Clipboard Pollution

Unlike earlier versions:
- Clipboard is NOT modified during drag
- Original clipboard content preserved
- User's clipboard remains clean
- Only drag pasteboard is used

## Supported Drop Targets

### Keynote

Primary use case - drop directly into presentations:
- Imports as grouped shape
- Maintains vector properties
- Fully editable in Keynote

### Other Applications

Any app that accepts file URLs:
- Sketch
- Figma
- Adobe apps (some)
- Preview
- Web browsers
- File managers

## Troubleshooting

### Drag Not Working

**Symptom**: Can't drag from preview

**Solutions**:
1. Make sure SVG is loaded (not empty)
2. Click directly on the preview area
3. Use click and drag (not just click)
4. Try in a different app first to test

### File Not Importing

**Symptom**: Drag works but target app doesn't import

**Solutions**:
1. Check that target app accepts SVG files
2. Try dropping into a different location
3. Verify SVG is valid (try opening in browser)
4. Check app's import settings

### Cursor Feedback Missing

**Symptom**: No visual feedback during drag

**Solutions**:
1. This is normal for some minimal themes
2. Check System Preferences > Accessibility
3. Drag is still working even if feedback is subtle
4. Try dragging to different location

## Technical Notes

### WKWebView and Dragging

The preview uses WKWebView for SVG rendering, but drag events are captured at the NSView level, not within the WebView. This prevents the WebView from consuming drag events and ensures proper macOS drag behavior.

### HTML Wrapper

SVGs are rendered with an HTML wrapper for proper scaling:

```html
<!DOCTYPE html>
<html>
<head>
    <style>
        body { margin: 0; padding: 0; overflow: hidden; }
        svg { width: 100%; height: 100%; object-fit: contain; }
    </style>
</head>
<body>
    {SVG content}
</body>
</html>
```

This ensures SVGs scale properly while still being draggable.

### Pasteboard Management

- Fresh pasteboard created for each drag
- File URL is the only item on drag pasteboard
- User's main clipboard untouched
- Minimizes data duplication

## Future Enhancements

Possible improvements:
1. Custom drag image showing SVG preview
2. Drag animation with zoom effect
3. Multiple file drag support
4. Drag progress indication
5. Direct Keynote slide drop targeting

## Summary

Vector Importer's drag and drop:
- ✓ Uses native macOS NSView drag sources
- ✓ Reliable and system-integrated
- ✓ Clean temporary file handling
- ✓ No clipboard pollution
- ✓ Works with any drop target
- ✓ Smooth user experience
- ✓ Follows macOS conventions

The implementation provides a native, professional drag and drop experience that feels like a built-in macOS application.