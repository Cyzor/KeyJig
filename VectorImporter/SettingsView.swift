import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)

            Divider()

            // Inkscape Section
            VStack(alignment: .leading, spacing: 8) {
                Text("External Dependencies")
                    .font(.headline)

                HStack(spacing: 12) {
                    // Status indicator
                    switch appState.inkscapeStatus {
                    case .checking:
                        ProgressView()
                            .scaleEffect(0.8)

                    case .installed(let path):
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title3)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Inkscape")
                                .font(.body)
                                .fontWeight(.semibold)
                            Text("Installed at \(URL(fileURLWithPath: path).lastPathComponent)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button("Reveal") {
                            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                        }
                        .font(.caption)

                    case .notInstalled:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.title3)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Inkscape")
                                .font(.body)
                                .fontWeight(.semibold)
                            Text("Not found — PDF/AI conversion disabled")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Link(destination: URL(string: "https://inkscape.org/release/")!) {
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
                .padding(12)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(6)
            }

            Spacer()

            Text("VectorImporter requires Inkscape to convert PDF and AI files to SVG. SVG files don't require Inkscape.")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(3)
        }
        .padding(24)
        .frame(minWidth: 400, minHeight: 250)
    }
}

#Preview {
    SettingsView(appState: AppState())
}
