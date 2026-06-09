import SwiftUI

private let inkscapeDownloadURL = URL(string: "https://inkscape.org/release/")!
private let ghostscriptWebURL = URL(string: "https://www.ghostscript.com/")!
private let mupdfWebURL = URL(string: "https://mupdf.com/")!
private let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
private let automationSettingsURL    = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

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
    @AppStorage("alwaysShowOptionalKeynoteButtons") private var alwaysShowOptionalKeynoteButtons = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
//            Text(NSLocalizedString(
//                "settings.section.integration",
//                comment: "Settings section heading"))
//                .font(.title3.weight(.semibold))
//
//            Divider()

            // Inkscape Section
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString(
                    "settings.external_deps",
                    comment: "Settings sub-heading for external tool dependencies"))
                    .font(.headline)

                HStack(spacing: 12) {
                    switch appState.inkscapeStatus {
                    case .checking:
                        ProgressView()
                            .scaleEffect(0.8)
                        Text(NSLocalizedString(
                            "settings.inkscape.checking",
                            comment: "Status shown while checking for Inkscape"))
                            .font(.body)

                    case .installed(let paths):
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title3)
                            .accessibilityLabel(NSLocalizedString(
                                "accessibility.inkscape_installed",
                                comment: "VoiceOver label for the green check shown when Inkscape is installed"))

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
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.title3)
                            .accessibilityLabel(NSLocalizedString(
                                "accessibility.inkscape_missing",
                                comment: "VoiceOver label for the warning icon shown when Inkscape is not installed"))

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

                        Button(NSLocalizedString(
                            "settings.inkscape.download",
                            comment: "Button label to download Inkscape")) {
                            NSWorkspace.shared.open(inkscapeDownloadURL)
                        }
                        .font(.caption)
                        .help(SettingsTooltips.downloadInkscape)
                    }
                }
                .padding(12)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(6)

                // ── Ghostscript ──────────────────────────────────────────
                CommandLineToolRow(
                    name: NSLocalizedString("settings.ghostscript.name",
                        comment: "Ghostscript application name"),
                    status: appState.ghostscriptStatus,
                    accessibilityInstalledLabel: NSLocalizedString(
                        "accessibility.ghostscript_installed",
                        comment: "VoiceOver label when Ghostscript is installed"),
                    accessibilityMissingLabel: NSLocalizedString(
                        "accessibility.ghostscript_missing",
                        comment: "VoiceOver label when Ghostscript is not installed"),
                    downloadURL: ghostscriptWebURL)

                // ── MuPDF (mutool) ───────────────────────────────────────
                CommandLineToolRow(
                    name: NSLocalizedString("settings.mutool.name",
                        comment: "MuPDF application name"),
                    status: appState.mutoolStatus,
                    accessibilityInstalledLabel: NSLocalizedString(
                        "accessibility.mutool_installed",
                        comment: "VoiceOver label when MuPDF is installed"),
                    accessibilityMissingLabel: NSLocalizedString(
                        "accessibility.mutool_missing",
                        comment: "VoiceOver label when MuPDF is not installed"),
                    downloadURL: mupdfWebURL)
            }

            // Per-tool descriptions
            VStack(alignment: .leading, spacing: 8) {
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

                Link("https://inkscape.org/",
                     destination: URL(string: "https://inkscape.org/")!)
                .font(.caption)
                .foregroundColor(.blue)

                Text(NSLocalizedString(
                    "settings.ghostscript.description",
                    comment: "Ghostscript description and Homebrew install hint"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Link("https://www.ghostscript.com/",
                     destination: ghostscriptWebURL)
                .font(.caption)
                .foregroundColor(.blue)

                Text(NSLocalizedString(
                    "settings.mutool.description",
                    comment: "MuPDF description and Homebrew install hint"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Link("https://mupdf.com/",
                     destination: mupdfWebURL)
                .font(.caption)
                .foregroundColor(.blue)

                Text(NSLocalizedString(
                    "settings.optional_tools.description",
                    comment: "Note that all external tools are optional"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()

            // Accessibility Section
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString(
                    "settings.section.permissions",
                    comment: "Settings section heading for OS permissions"))
                    .font(.headline)

                HStack(spacing: 12) {
                    if appState.accessibilityGranted {
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
                        Text(appState.accessibilityGranted
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

                    if !appState.accessibilityGranted {
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

                // Automation row — only surfaced when explicitly denied.
                // "Not yet determined" is fine: the system will prompt on first
                // use and grant automatically on approval, so no warning needed.
                if appState.keynoteAutomationGranted == false {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.title3)
                            .accessibilityLabel(NSLocalizedString(
                                "accessibility.automation_denied",
                                comment: "VoiceOver label when Automation permission for Keynote is denied"))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString(
                                "settings.automation.name",
                                comment: "Automation permission row label"))
                                .font(.body)
                                .fontWeight(.semibold)
                            Text(NSLocalizedString(
                                "settings.automation.denied",
                                comment: "Status when Automation access for Keynote has been revoked"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button(NSLocalizedString(
                            "settings.accessibility.open_settings",
                            comment: "Button that opens System Settings")) {
                            NSWorkspace.shared.open(automationSettingsURL)
                        }
                        .font(.caption)
                        .help(NSLocalizedString(
                            "tooltip.settings.automation_open",
                            comment: "Tooltip for the Open Settings button in the Automation row"))
                    }
                    .padding(12)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(6)
                }
            }

            Text(NSLocalizedString(
                "settings.accessibility.description",
                comment: "Explanatory text about why Accessibility permission is needed"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if appState.keynoteAutomationGranted == false {
                Text(NSLocalizedString(
                    "settings.automation.description",
                    comment: "Explanatory text shown when Automation permission for Keynote has been revoked"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Appearance Section
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString(
                    "settings.section.appearance",
                    comment: "Settings section heading for appearance options"))
                    .font(.headline)

                Toggle(isOn: $alwaysShowOptionalKeynoteButtons) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NSLocalizedString(
                            "settings.appearance.always_show_keynote_buttons",
                            comment: "Toggle label: always show the optional Keynote pull buttons"))
                            .font(.body)
                        Text(NSLocalizedString(
                            "settings.appearance.always_show_keynote_buttons.description",
                            comment: "Description for the always-show Keynote buttons toggle"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 400)
        .sheet(isPresented: $showingInkscapeDetails) {
            InkscapeDetailsView(appState: appState, isPresented: $showingInkscapeDetails)
        }
    }
}

// MARK: - Command-line tool row (Ghostscript, MuPDF)

/// Displays the installed/not-found status of a single command-line tool.
/// Simpler than the Inkscape row: only one path, no details sheet.
private struct CommandLineToolRow: View {
    let name: String
    let status: CommandLineToolStatus
    let accessibilityInstalledLabel: String
    let accessibilityMissingLabel: String
    var downloadURL: URL? = nil

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            switch status {
            case .checking:
                ProgressView().scaleEffect(0.8)
                Text(NSLocalizedString(
                    "settings.inkscape.checking",
                    comment: "Status shown while checking for a tool"))

            case .installed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title3)
                    .accessibilityLabel(accessibilityInstalledLabel)

            case .notInstalled:
                Image(systemName: "minus.circle")
                    .foregroundColor(.secondary)
                    .font(.title3)
                    .accessibilityLabel(accessibilityMissingLabel)
            }

            // Name + subtitle
            switch status {
            case .checking:
                EmptyView()

            case .installed(let path):
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.body).fontWeight(.semibold)
                    Text(path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(NSLocalizedString(
                    "settings.cmdtool.reveal",
                    comment: "Button to reveal a command-line tool in Finder")) {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
                .font(.caption)

            case .notInstalled:
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.body).fontWeight(.semibold)
                    Text(NSLocalizedString(
                        "settings.cmdtool.not_found",
                        comment: "Status shown when a command-line tool is not installed"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let url = downloadURL {
                    Button(NSLocalizedString(
                        "settings.inkscape.download",
                        comment: "Button label to download a tool")) {
                        NSWorkspace.shared.open(url)
                    }
                    .font(.caption)
                    .help(NSLocalizedString(
                        "tooltip.settings.download_tool",
                        comment: "Tooltip for the Download button on a command-line tool row"))
                }
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(6)
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
