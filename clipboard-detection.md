# Clipboard Detection Feature

## Overview

Vector Importer now automatically detects SVG content in the clipboard and loads it into the preview whenever the app is launched or reactivated. This feature streamlines the workflow by eliminating the need to manually trigger clipboard conversion.

## How It Works

### Automatic Detection Points

The app checks the clipboard for SVG content at these key moments:

1. **On Launch** - When the app first starts
2. **On Reactivation** - When you switch back to Vector Importer from another app
3. **When Showing Popover** - When you click the menu bar icon to show the popover
4. **When Showing Panel** - When you use File > Show Panel
5. **When Creating Floating Window** - When you open File > New Floating Window

### Silent Conversion

- The clipboard is checked but **never modified** by the detection process
- If SVG content is found, it's loaded into the app's preview
- The original clipboard content remains untouched
- Users can still manually use "Bridge Clipboard to Keynote" if needed

### Smart Detection

The detection is intelligent:
- Only loads SVG if clipboard content has actually changed
- Avoids redundant loading of the same content
- Checks for both explicit SVG type and raw SVG text in clipboard

## Drag and Drop

The preview is now a drag-and-drop target without clipboard modification:

1. SVG content is automatically detected and displayed in preview
2. You can drag the preview directly into Keynote
3. The drag operation doesn't modify your clipboard
4. Original clipboard content is preserved for other uses

### Example Workflow

```
1. Copy SVG from design app (e.g., Illustrator, Figma)
2. Switch to Vector Importer → SVG automatically appears in preview
3. Drag preview into Keynote presentation
4. Original clipboard still contains the SVG data
5. Continue working without clipboard interference
```

## Implementation Details

### Detection Function

The `checkAndLoadClipboardSVG()` method:
- Calls `convertClipboardToSVG()` to parse clipboard content
- Compares with current SVG state to avoid redundant loads
- Updates `AppState.shared.svgString` if new content found
- Runs silently without user notifications

### Drag Operation Changes

The `.onDrag` modifier in ContentView:
- Writes SVG to a temporary file
- Provides that file for drag operations
- **Does not call** `svgToClipboard()` anymore
- Preserves the user's original clipboard content

### AppDelegate Integration

New method in AppDelegate:
```swift
func applicationWillBecomeActive(_ notification: Notification) {
    checkAndLoadClipboardSVG()
}
```

This ensures clipboard is checked whenever the app comes to focus.

## User Experience Benefits

### Faster Workflow
- No need to explicitly convert clipboard content
- Preview appears immediately when app is activated
- One drag operation into Keynote (no paste step needed)

### Non-Intrusive
- Clipboard content is never replaced
- Works silently in the background
- User remains in control of their clipboard

### Drag-Drop Native
- Preview can be dragged directly into Keynote
- Familiar macOS drag-and-drop interaction
- Clean, direct import workflow

## Interaction Examples

### Scenario 1: Quick Import from Design App

```
Affinity Designer → Copy SVG
                  ↓
Click Vector Importer in menu bar
                  ↓
Preview appears automatically
                  ↓
Drag into Keynote
                  ↓
Done! Clipboard still has original SVG
```

### Scenario 2: Multitasking

```
Working in Sketch, copy component
                  ↓
Switch to Keynote to add slide
                  ↓
Click Vector Importer icon
                  ↓
SVG from Sketch appears in preview
                  ↓
Drag into Keynote slide
                  ↓
Switch back to Sketch (clipboard unchanged)
```

### Scenario 3: Multiple Files

```
Open floating window (Cmd+Shift+N)
                  ↓
Copy SVG from design app #1
                  ↓
Preview updates automatically
                  ↓
Drag into Keynote
                  ↓
Copy SVG from design app #2
                  ↓
Preview updates automatically
                  ↓
Drag into Keynote again
                  ↓
No clipboard conflicts!
```

## Technical Notes

### Clipboard Detection Methods

The app supports multiple clipboard formats:

1. **Explicit SVG Type** - Apps like Affinity Designer provide `public.svg-image` type
2. **Raw SVG Text** - Any app that copies text containing `<svg` tag
3. **Both Formats** - Apps that provide multiple representations

### State Management

- Clipboard check is lightweight (no UI updates unless content changed)
- Comparisons prevent unnecessary state updates
- AppState singleton maintains SVG across all windows
- Multiple windows share the same detected SVG

### Performance

- Detection runs synchronously at key points
- No continuous polling or background threads
- No performance impact on normal app operations
- Checks are fast (simple string comparison)

## Configuration

The detection is always enabled and has no configuration options. Future versions could add:
- Option to disable auto-detection
- Preference for detection frequency
- Filter for specific SVG sources

## Limitations

1. **One-way Detection** - Only clipboard → app, never app → clipboard automatically
2. **No History** - Previous clipboard content is not stored or cached
3. **Format Dependent** - Quality depends on how the source app exports SVG
4. **No Notifications** - Detection happens silently (may add optional status updates later)

## Troubleshooting

### SVG doesn't appear in preview

**Possible causes:**
1. Clipboard doesn't contain SVG data
2. SVG is in a format the app doesn't recognize
3. The clipboard content is very large or malformed

**Solutions:**
1. Use File > Open SVG... to manually select a file
2. Try the "Bridge Clipboard to Keynote" button
3. Check that your design app exports valid SVG

### Want to prevent auto-detection

Currently not possible, but you can:
1. Use File > Open SVG... for manual control
2. Use "Bridge Clipboard to Keynote" explicitly
3. Clear clipboard if detection is interfering

## Future Enhancements

Potential improvements:
1. Add visual indication that clipboard was detected
2. Optional notification when SVG is detected
3. History of recent clipboard items
4. Per-window clipboard detection (for floating windows)
5. Preferences to enable/disable detection
6. Status message showing detection status

## Summary

The automatic clipboard detection feature makes Vector Importer seamless and non-intrusive:
- Detects SVG in clipboard on launch and reactivation
- Never modifies the clipboard content
- Enables drag-and-drop workflow without clipboard pollution
- Works across popover and floating window modes
- Supports multiple SVG format sources

This enhancement makes the app feel more like a native macOS utility that understands your workflow and acts invisibly in the background.