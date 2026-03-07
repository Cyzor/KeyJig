import SwiftUI
import SVGWebView
import WebKit

struct ContentView: View {
    @ObservedObject var appState = AppState.shared
    @State var localStatus: String = "Ready to bridge vectors";
    
    var body: some View {
        VStack(spacing: 0) {
            // Preview Area (Draggable)
            ZStack {
                Color(NSColor.windowBackgroundColor)
                
                if !appState.svgString.isEmpty {
                    // The actual SVG rendered in a WebView
                    SVGWebView(svg: appState.svgString)
                        .padding(10)
                    
                    // Transparent overlay to capture drag events (WebViews swallow them)
                    Group {
                        if #available(macOS 12.0, *) {
                            Color.white.opacity(0.001)
                                .onDrag {
                                    _ = svgToClipboard(svgData: appState.svgString)
                                    return NSItemProvider(contentsOf: getTempSVGURL()) ?? NSItemProvider()
                                } preview: {
                                    // Professional "Vector Card" preview
                                    VStack(spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color.blue.opacity(0.1))
                                            Text("SVG")
                                                .font(.system(size: 30, weight: .black, design: .monospaced))
                                                .foregroundColor(.blue)
                                        }
                                        .frame(width: 80, height: 80)
                                        
                                        Text("Vector Asset")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundColor(.primary)
                                    }
                                    .frame(width: 140, height: 140)
                                    .background(Color(NSColor.windowBackgroundColor))
                                    .cornerRadius(12)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                                    )
                                    .shadow(radius: 10)
                                }
                        } else {
                            // Fallback for macOS 10.15/11.0
                            Color.white.opacity(0.001)
                                .onDrag {
                                    _ = svgToClipboard(svgData: appState.svgString)
                                    return NSItemProvider(contentsOf: getTempSVGURL()) ?? NSItemProvider()
                                }
                        }
                    }
                } else {
                    VStack(spacing: 8) {
                        Image("Placeholder")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 90, height: 90)
                            .foregroundColor(.secondary)
                        Text("No SVG Loaded")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(height: 180)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .padding([.horizontal, .top])
            
            // Status area
            Text(localStatus)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .padding(.top, 12)
                .foregroundColor(.secondary)
                .frame(height: 50)
            
            Divider().padding(.vertical, 8)
            
            // Action Buttons
            VStack(spacing: 8) {
                Button(action: {
                    let picked = browseFile();
                    if !picked.isEmpty {
                        appState.svgString = picked;
                        localStatus = "Loaded: " + (URL(fileURLWithPath: appState.svgURL).lastPathComponent);
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
                            localStatus = "Bridged! Switch to Keynote and Paste (⌘V).";
                        }
                    } else {
                        localStatus = "No SVG data found on clipboard.";
                    }
                }) {
                    Text("Bridge Clipboard to Keynote")
                        .frame(maxWidth: .infinity)
                }
                
                HStack(spacing: 8) {
                    Button("Copy Preview") {
                        if (svgToClipboard(svgData: appState.svgString)) {
                            localStatus = "Preview copied for Keynote.";
                        }
                    }
                    .disabled(appState.svgString.isEmpty)
                    .frame(maxWidth: .infinity)
                    
                    Button("PDF Fallback") {
                        if (convertWithInkscape(svgPath: appState.svgURL)) {
                            localStatus = "Copied as PDF (Fallback)";
                        } else {
                            localStatus = "Inkscape not found";
                        }
                    }
                    .disabled(appState.svgURL.isEmpty)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal)
            
            Spacer(minLength: 16)
            
            // Footer
            HStack {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                
                Spacer()
                
                Text("VectorImporter")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        }
        .frame(width: 380, height: 480) 
    }
}

func browseFile() -> String {
    let dialog = NSOpenPanel();
    dialog.title                   = "Choose a .svg file";
    dialog.showsResizeIndicator    = true;
    dialog.showsHiddenFiles        = false;
    dialog.canChooseDirectories    = false;
    dialog.canCreateDirectories    = true;
    dialog.allowsMultipleSelection = false;
    dialog.allowedFileTypes        = ["svg"];

    if (dialog.runModal() == NSApplication.ModalResponse.OK) {
        if let result = dialog.url {
            AppState.shared.svgURL = result.path;
            do {
                return try String(contentsOf: result, encoding: .utf8);
            } catch {
                NSLog("Error reading file");
            }
        }
    }
    return "";
}
