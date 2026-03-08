import SVGWebView
import SwiftUI
import WebKit

struct ContentView: View {
    @ObservedObject var appState = AppState.shared
    @State var localStatus: String = "Ready to bridge vectors"

    var body: some View {
        VStack(spacing: 0) {
            // Preview Area (Draggable) - Fills entire container
            if !appState.svgString.isEmpty {
                ZStack {
                    Color(NSColor.windowBackgroundColor)

                    SVGWebView(svg: appState.svgString)
                        .padding(5)

                    // Transparent overlay to capture drag events
                    if #available(macOS 12.0, *) {
                        Color.white.opacity(0.001)
                            .contentShape(Rectangle())
                            .onDrag {
                                let tempURL = getTempSVGURL()
                                do {
                                    try appState.svgString.write(
                                        to: tempURL, atomically: true, encoding: .utf8)
                                } catch {
                                    NSLog("Error writing temp SVG: \(error)")
                                }
                                return NSItemProvider(contentsOf: tempURL) ?? NSItemProvider()
                            } preview: {
                                VStack(spacing: 12) {
                                    SVGWebView(svg: appState.svgString)
                                        .scaledToFit()
                                        .frame(width: 120, height: 120)
                                        .background(Color(NSColor.windowBackgroundColor))
                                        .cornerRadius(8)

                                    Text("Drag SVG into Keynote…")
                                        .font(.system(.caption, design: .rounded))
                                        .fontWeight(.semibold)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.black.opacity(0.7))
                                        .cornerRadius(6)
                                }
                                .padding(12)
                                .background(Color(NSColor.windowBackgroundColor))
                                .cornerRadius(12)
                                .shadow(radius: 8)
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
                    } else {
                        Color.white.opacity(0.001)
                            .contentShape(Rectangle())
                            .onDrag {
                                let tempURL = getTempSVGURL()
                                do {
                                    try appState.svgString.write(
                                        to: tempURL, atomically: true, encoding: .utf8)
                                } catch {
                                    NSLog("Error writing temp SVG: \(error)")
                                }
                                return NSItemProvider(contentsOf: tempURL) ?? NSItemProvider()
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
                            localStatus = "Bridged! Switch to Keynote and Paste (⌘V)."
                        }
                    } else {
                        localStatus = "No SVG data found on clipboard."
                    }
                }) {
                    Text("Bridge Clipboard to Keynote")
                        .frame(maxWidth: .infinity)
                }

                HStack(spacing: 8) {
                    Button("Copy Preview") {
                        if svgToClipboard(svgData: appState.svgString) {
                            localStatus = "Preview copied for Keynote."
                        }
                    }
                    .disabled(appState.svgString.isEmpty)
                    .frame(maxWidth: .infinity)

                    Button("PDF Fallback") {
                        if convertWithInkscape(svgPath: appState.svgURL) {
                            localStatus = "Copied as PDF (Fallback)"
                        } else {
                            localStatus = "Inkscape not found"
                        }
                    }
                    .disabled(appState.svgURL.isEmpty)
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
