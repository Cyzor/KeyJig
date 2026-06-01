import SwiftUI

private let inkscapeDownloadURL = URL(string: "https://inkscape.org/release/")!
private let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

// MARK: - Tooltip Text Constants for Settings

struct SettingsTooltips {
    static let inkscapeDetails = NSLocalizedString(
        "tooltip.settings.details",
        comment: "Tooltip for the Details button in the Inkscape row")

    static let downloadInkscape = NSLocalizedString(
        "tooltip.settings.download",
        comment: "Tooltip for the Download button when Inkscape is not installed")

    static let accessibilityOpen = NSLocalizedString(
        "tooltip.settings.accessibility_open",
        comment: "Tooltip for the Open Settings button in the Accessibility row")
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var showingInkscapeDetails = false
    @State private var accessibilityTrusted: Bool = AXIsProcessTrusted()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString(
                "settings.section.integration",
                comment: "Settings section heading"))
                .font(.title3.weight(.semibold))

            Divider()

            // Inkscape Section
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString(
                    "settings.external_deps",
                    comment: "Settings sub-heading for external tool dependencies"))
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
                        Text(NSLocalizedString(
                            "settings.inkscape.checking",
                            comment: "Status shown while checking for Inkscape"))
                            .font(.body)

                    case .installed(let paths):
                        if #available(macOS 11.0, *) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.title3)
                                .accessibilityLabel(NSLocalizedString(
                                    "accessibility.inkscape_installed",
                                    comment: "VoiceOver label for the green check shown when Inkscape is installed"))
                        } else {
                            Text("✓")
                                .foregroundColor(.green)
                                .font(.headline)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString(
                                "settings.inkscape.name",
                                comment: "Inkscape application name label"))
                                .font(.body)
                                .fontWeight(.semibold)
                            Text(String.localizedStringWithFormat(
                                NSLocalizedString(
                                    "settings.inkscape.locations",
                                    comment: "Installed Inkscape location count, e.g. 'Installed — 2 locations'"),
                                paths.count))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button(NSLocalizedString(
                            "settings.inkscape.details",
                            comment: "Button that opens the Inkscape installation details sheet")) {
                            showingInkscapeDetails = true
                        }
                        .font(.caption)
                        .help(SettingsTooltips.inkscapeDetails)

                    case .notInstalled:
                        if #available(macOS 11.0, *) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.title3)
                                .accessibilityLabel(NSLocalizedString(
                                    "accessibility.inkscape_missing",
                                    comment: "VoiceOver label for the warning icon shown when Inkscape is not installed"))
                        } else {
                            Text("⚠")
                                .foregroundColor(.orange)
                                .font(.headline)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString(
                                "settings.inkscape.name",
                                comment: "Inkscape application name label"))
                                .font(.body)
                                .fontWeight(.semibold)
                            Text(NSLocalizedString(
                                "settings.inkscape.not_found",
                                comment: "Status shown when Inkscape is not installed"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if #available(macOS 11.0, *) {
                            Link(destination: inkscapeDownloadURL) {
                                Text(NSLocalizedString(
                                    "settings.inkscape.download",
                                    comment: "Button label to download Inkscape"))
                                    .font(.caption)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(4)
                            }
                            .help(SettingsTooltips.downloadInkscape)
                        } else {
                            Button(action: {
                                NSWorkspace.shared.open(inkscapeDownloadURL)
                            }) {
                                Text(NSLocalizedString(
                                    "settings.inkscape.download",
                                    comment: "Button label to download Inkscape"))
                                    .font(.caption)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(4)
                            }
                            .help(SettingsTooltips.downloadInkscape)
                        }
                    }
                }
                .padding(12)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(6)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString(
                    "settings.inkscape.description",
                    comment: "Explanatory text about Inkscape's role in the app"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Text(NSLocalizedString(
                    "settings.inkscape.details_label",
                    comment: "Label preceding the Inkscape website link"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fontWeight(.semibold)

                if #available(macOS 11.0, *) {
                    Link(
                        "https://inkscape.org/", destination: URL(string: "https://inkscape.org/")!
                    )
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
            Divider()

            // Accessibility Section
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString(
                    "settings.section.permissions",
                    comment: "Settings section heading for OS permissions"))
                    .font(.headline)

                HStack(spacing: 12) {
                    if accessibilityTrusted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title3)
                            .accessibilityLabel(NSLocalizedString(
                                "accessibility.accessibility_granted",
                                comment: "VoiceOver label when Accessibility permission is granted"))
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.title3)
                            .accessibilityLabel(NSLocalizedString(
                                "accessibility.accessibility_needed",
                                comment: "VoiceOver label when Accessibility permission is not granted"))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(NSLocalizedString(
                            "settings.accessibility.name",
                            comment: "Accessibility permission row label"))
                            .font(.body)
                            .fontWeight(.semibold)
                        Text(accessibilityTrusted
                            ? NSLocalizedString(
                                "settings.accessibility.granted",
                                comment: "Status when Accessibility permission is granted")
                            : NSLocalizedString(
                                "settings.accessibility.needed",
                                comment: "Status when Accessibility permission is not granted"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if !accessibilityTrusted {
                        Button(NSLocalizedString(
                            "settings.accessibility.open_settings",
                            comment: "Button that opens System Settings to grant Accessibility permission")) {
                            NSWorkspace.shared.open(accessibilitySettingsURL)
                        }
                        .font(.caption)
                        .help(SettingsTooltips.accessibilityOpen)
                    }
                }
                .padding(12)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(6)
            }

            Text(NSLocalizedString(
                "settings.accessibility.description",
                comment: "Explanatory text about why Accessibility permission is needed"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(minWidth: 400)
        .onAppear {
            accessibilityTrusted = AXIsProcessTrusted()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = AXIsProcessTrusted()
        }
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
                Text(NSLocalizedString(
                    "settings.inkscape.installation_title",
                    comment: "Title of the Inkscape installation details sheet"))
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(NSLocalizedString(
                    "settings.inkscape.done",
                    comment: "Button to close the Inkscape details sheet")) {
                    isPresented = false
                }
                .font(.caption)
                .help(NSLocalizedString(
                    "tooltip.settings.done",
                    comment: "Tooltip for the Done button in the Inkscape details sheet"))
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
                                        Text(NSLocalizedString(
                                            "settings.inkscape.copy",
                                            comment: "Button to copy an Inkscape path to clipboard"))
                                            .font(.caption)
                                    }
                                    .help(NSLocalizedString(
                                        "tooltip.settings.copy_path",
                                        comment: "Tooltip for the Copy path button"))

                                    Button(action: {
                                        NSWorkspace.shared.selectFile(
                                            path, inFileViewerRootedAtPath: "")
                                    }) {
                                        Text(NSLocalizedString(
                                            "settings.inkscape.reveal",
                                            comment: "Button to reveal an Inkscape installation in Finder"))
                                            .font(.caption)
                                    }
                                    .help(NSLocalizedString(
                                        "tooltip.settings.reveal",
                                        comment: "Tooltip for the Reveal in Finder button"))
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
                Text(NSLocalizedString(
                    "settings.inkscape.no_installation",
                    comment: "Message shown in the details sheet when no Inkscape is found"))
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
