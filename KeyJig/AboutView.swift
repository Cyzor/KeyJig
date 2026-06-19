import AppKit
import SwiftUI

// MARK: - About Window Controller

final class AboutWindowController: NSWindowController, NSWindowDelegate {

    init() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("dialog.about.title", comment: "About window title")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.identifier = NSUserInterfaceItemIdentifier("AboutWindow")
        window.contentMinSize = NSSize(width: 460, height: 300)

        window.contentViewController = NSHostingController(rootView: AboutView(version: version) {
            window.close()
        })
        window.setContentSize(NSSize(width: 460, height: 480))

        window.center()

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        AppDelegate.shared?.aboutWindowController = nil
    }
}

// MARK: - About View

private struct AboutView: View {
    let version: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {

            // ── Icon + name + version ─────────────────────────────────────
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)

                Text(NSLocalizedString("dialog.about.title",
                    comment: "App name in the About panel"))
                    .font(.title.bold())

                Text("Version \(version)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 32)
            .padding(.bottom, 24)

            Divider()

            // ── Body ──────────────────────────────────────────────────────
            VStack(spacing: 16) {
                Text(NSLocalizedString("dialog.about.body",
                    comment: "About panel body: tagline and copyright lines"))
                    .multilineTextAlignment(.center)

                VStack(spacing: 4) {
                    Text(NSLocalizedString("dialog.about.noun_project",
                        comment: "About panel Noun Project attribution label"))
                        .foregroundColor(.secondary)
                    Link("thenounproject.com/legal/terms-of-use",
                         destination: URL(string: "https://thenounproject.com/legal/terms-of-use/#icon-licenses")!)
                }
                .font(.footnote)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(28)

            Divider()

            // ── Buttons ───────────────────────────────────────────────────
            HStack {
                Button(NSLocalizedString("dialog.about.website",
                    comment: "About panel button that opens the project website")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/Cyzor/KeyJig")!)
                }
                Spacer()
                Button(NSLocalizedString("dialog.about.button",
                    comment: "About panel dismiss button")) {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 460)
    }
}
