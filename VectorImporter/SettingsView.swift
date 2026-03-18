import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var showingInkscapeDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Integration")
                .font(.system(size: 18, weight: .semibold))

            Divider()

            // Inkscape Section
            VStack(alignment: .leading, spacing: 8) {
                Text("External Dependencies")
                    .font(.headline)

                HStack(spacing: 12) {
                    switch appState.inkscapeStatus {
                    case .checking:
                        if #available(macOS 11.0, *) {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Text("…")
                        }
                        Text("Checking…")
                            .font(.body)

                    case .installed(let paths):
                        if #available(macOS 11.0, *) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.title3)
                        } else {
                            Text("✓")
                                .foregroundColor(.green)
                                .font(.headline)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Inkscape")
                                .font(.body)
                                .fontWeight(.semibold)
                            Text("Installed — \(paths.count) location\(paths.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button("Details") {
                            showingInkscapeDetails = true
                        }
                        .font(.caption)

                    case .notInstalled:
                        if #available(macOS 11.0, *) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.title3)
                        } else {
                            Text("⚠")
                                .foregroundColor(.orange)
                                .font(.headline)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Inkscape")
                                .font(.body)
                                .fontWeight(.semibold)
                            Text("Not found")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if #available(macOS 11.0, *) {
                            Link(destination: URL(string: "https://inkscape.org/release/")!) {
                                Text("Download")
                                    .font(.caption)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(4)
                            }
                        } else {
                            Button(action: {
                                NSWorkspace.shared.open(URL(string: "https://inkscape.org/release/")!)
                            }) {
                                Text("Download")
                                    .font(.caption)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(4)
                            }
                        }
                    }
                }
                .padding(12)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(6)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Text("This utility relies on the open-source graphics application Inkscape for some conversions.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(nil)

                Text("Details:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fontWeight(.semibold)

                if #available(macOS 11.0, *) {
                    Link("https://inkscape.org/", destination: URL(string: "https://inkscape.org/")!)
                        .font(.caption)
                        .foregroundColor(.blue)
                } else {
                    Button(action: {
                        NSWorkspace.shared.open(URL(string: "https://inkscape.org/")!)
                    }) {
                        Text("https://inkscape.org/")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(24)
        .frame(minWidth: 400, minHeight: 320)
        .sheet(isPresented: $showingInkscapeDetails) {
            InkscapeDetailsView(appState: appState, isPresented: $showingInkscapeDetails)
        }
    }
}

// MARK: - Inkscape Details Sheet

struct InkscapeDetailsView: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Inkscape Installation")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Done") {
                    isPresented = false
                }
                .font(.caption)
            }

            if case .installed(let paths) = appState.inkscapeStatus {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(paths, id: \.self) { path in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                let textView = Text(path)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(3)

                                if #available(macOS 12.0, *) {
                                    textView.textSelection(.enabled)
                                } else {
                                    textView
                                }

                                HStack(spacing: 8) {
                                    Button(action: {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(path, forType: .string)
                                    }) {
                                        Text("Copy")
                                            .font(.system(size: 11))
                                    }

                                    Button(action: {
                                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                                    }) {
                                        Text("Reveal")
                                            .font(.system(size: 11))
                                    }
                                }
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(Color(.controlBackgroundColor))
                        .cornerRadius(4)
                    }
                }
            } else {
                Text("No Inkscape installation found.")
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 250)
    }
}

#Preview {
    SettingsView(appState: AppState())
}
