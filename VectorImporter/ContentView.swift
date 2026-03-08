import AppKit
import SVGWebView
import SwiftUI
import WebKit

// Custom NSView for proper drag handling with cursor-relative offset
class DraggablePreviewView: NSView {
    var onDragStart: (() -> URL?)?

    override func mouseDown(with event: NSEvent) {
        guard let fileURL = onDragStart?() else {
            super.mouseDown(with: event)
            return
        }

        // Get the mouse location in this view's coordinates
        let dragPoint = event.locationInWindow
        let viewPoint = self.convert(dragPoint, from: nil)

        // Create drag image - a simple box with icon and text
        let dragImage = NSImage(size: NSSize(width: 180, height: 180))
        dragImage.lockFocus()

        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: 180, height: 180), xRadius: 12, yRadius: 12
        ).fill()

        // Draw SF Symbol icon
        if #available(macOS 11.0, *) {
            if let icon = NSImage(
                systemSymbolName: "photo.fill.on.rectangle.fill", accessibilityDescription: "image")
            {
                let iconRect = NSRect(x: 50, y: 60, width: 80, height: 80)
                icon.draw(in: iconRect)
            }
        } else {
            // Fallback for older macOS: draw a simple circle as placeholder
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 65, y: 105, width: 50, height: 50)).fill()
        }

        let style = NSMutableParagraphStyle()
        style.alignment = .center

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]

        let text = NSAttributedString(string: "Drag into Keynote", attributes: attrs)
        let textRect = NSRect(x: 0, y: 15, width: 180, height: 30)
        text.draw(in: textRect)

        dragImage.unlockFocus()

        // Create dragging item with the file URL
        let draggingItem = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        let imageFrame = NSRect(x: viewPoint.x - 90, y: viewPoint.y - 90, width: 180, height: 180)
        draggingItem.setDraggingFrame(imageFrame, contents: dragImage)

        // Begin dragging session
        _ = self.beginDraggingSession(
            with: [draggingItem], event: event, source: self)
    }
}

// Make it a dragging source
extension DraggablePreviewView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        return .copy
    }
}

// SwiftUI wrapper for the custom drag view
struct DraggablePreviewViewWrapper: NSViewRepresentable {
    let svgString: String
    var onDragStart: (() -> URL?)?

    func makeNSView(context: Context) -> DraggablePreviewView {
        let view = DraggablePreviewView()
        view.onDragStart = onDragStart
        return view
    }

    func updateNSView(_ nsView: DraggablePreviewView, context: Context) {
        nsView.onDragStart = onDragStart
    }
}

extension DraggablePreviewViewWrapper {
    func onDragStart(_ callback: @escaping () -> URL?) -> Self {
        var copy = self
        copy.onDragStart = callback
        return copy
    }
}

struct ContentView: View {
    @ObservedObject var appState = AppState.shared
    @State var localStatus: String = "Awaiting vector data for conversion"

    var body: some View {
        VStack(spacing: 0) {
            // Preview Area (Draggable) - Fills entire container
            if !appState.svgString.isEmpty {
                ZStack {
                    Color(NSColor.windowBackgroundColor)

                    SVGWebView(svg: appState.svgString)
                        .padding(5)

                    // Custom NSView wrapper for proper drag handling
                    DraggablePreviewViewWrapper(svgString: appState.svgString)
                        .onDragStart { [weak appState] in
                            let tempURL = getTempSVGURL()
                            do {
                                try appState?.svgString.write(
                                    to: tempURL, atomically: true, encoding: .utf8)
                            } catch {
                                NSLog("Error writing temp SVG: \(error)")
                                return nil
                            }
                            return tempURL
                        }
                        .contextMenu {
                            Button("Convert and Copy for Keynote") {
                                let svg = appState.svgString
                                if !svg.isEmpty {
                                    if svgToClipboard(svgData: svg) {
                                        localStatus = "Converted and copied for Keynote!"
                                    }
                                }
                            }
                        }
                }
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .padding([.horizontal, .top])
                .frame(minHeight: 100, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image("Placeholder")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)
                        .foregroundColor(.secondary)
                    Text("No SVG Loaded")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Open a file, paste from clipboard, or drag SVG content here")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .padding([.horizontal, .top])
            }

            // Status area
            Text(localStatus)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .foregroundColor(.secondary)
                .frame(height: 50, alignment: .top)

            Divider().padding(.vertical, 8)

            // Action Buttons
            VStack(spacing: 8) {
                Button(action: {
                    let picked = browseFile()
                    if !picked.isEmpty {
                        appState.svgString = picked
                        localStatus =
                            "Loaded: " + (URL(fileURLWithPath: appState.svgURL).lastPathComponent)
                    }
                }) {
                    Text("Open SVG File...")
                        .frame(maxWidth: .infinity)
                }

                Button(action: {
                    let svg = convertClipboardToSVG()
                    if !svg.isEmpty {
                        appState.svgString = svg
                        if svgToClipboard(svgData: svg) {
                            localStatus = "Converted! Switch to Keynote and Paste (⌘V)."
                        }
                    } else {
                        localStatus = "No SVG data found on clipboard."
                    }
                }) {
                    Text("Convert into Editable Keynote Format")
                        .frame(maxWidth: .infinity)
                }

            }
            .padding(.horizontal)

            Spacer(minLength: 0)

            // Footer
            HStack {
                Text("VectorImporter")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        }
    }
}

func browseFile() -> String {
    let dialog = NSOpenPanel()
    dialog.title = "Choose a .svg file"
    dialog.showsHiddenFiles = false
    dialog.canChooseDirectories = false
    dialog.canCreateDirectories = true
    dialog.allowsMultipleSelection = false
    dialog.allowedFileTypes = ["svg"]

    if dialog.runModal() == NSApplication.ModalResponse.OK {
        if let result = dialog.url {
            AppState.shared.svgURL = result.path
            do {
                return try String(contentsOf: result, encoding: .utf8)
            } catch {
                NSLog("Error reading file")
            }
        }
    }
    return ""
}

#Preview {
    ContentView()
        .frame(width: 480, height: 680)
}
