import SwiftUI
import SVGWebView
import WebKit

struct ContentView: View {
    @ObservedObject var appState = AppState.shared
    @State var localStatus: String = "Ready to bridge vectors";
    
    var body: some View {
        VStack(spacing: 0) {
            // Preview Area
            ZStack {
                Color(NSColor.windowBackgroundColor)
                
                if !appState.svgString.isEmpty {
                    SVGWebView(svg: appState.svgString)
                        .padding(10)
                } else {
                    VStack(spacing: 8) {
                        // SF Symbols are 11.0+, so we use a text fallback or simple shape
                        Text("􀈄") // Folder/Download symbol often works if font supports it, else "SVG"
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No SVG Loaded")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(height: 180)
            .cornerRadius(8)
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
                            localStatus = "Clipboard content bridged! Paste into Keynote.";
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
