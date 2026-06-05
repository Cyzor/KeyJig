import AppKit
import SwiftUI

// MARK: - Help Window Controller

class HelpWindowController: NSWindowController {

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString(
            "dialog.help.title",
            comment: "Help window title")
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("HelpWindow")

        let didRestore = window.setFrameUsingName("HelpWindow")
        if !didRestore { window.center() }
        window.setFrameAutosaveName("HelpWindow")

        let host = NSHostingController(rootView: HelpView())
        if #available(macOS 13.0, *) {
            host.sizingOptions = .minSize
        }
        window.contentViewController = host

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Help View

struct HelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HelpSection(
                symbol: "arrow.down.doc.fill",
                color: .blue,
                title: NSLocalizedString(
                    "help.section.import.title",
                    comment: "Help: Import section heading"),
                content: NSLocalizedString(
                    "help.section.import.body",
                    comment: "Help: Import section bullet points")
            )
            Divider()
            HelpSection(
                symbol: "document.on.document.fill",
                color: .green,
                title: NSLocalizedString(
                    "help.section.keynote.title",
                    comment: "Help: Send to Keynote section heading"),
                content: NSLocalizedString(
                    "help.section.keynote.body",
                    comment: "Help: Send to Keynote section bullet points")
            )
            Divider()
            HelpSection(
                symbol: "document.badge.ellipsis.fill",
                color: .orange,
                title: NSLocalizedString(
                    "help.section.pull.title",
                    comment: "Help: Pull from Keynote section heading"),
                content: NSLocalizedString(
                    "help.section.pull.body",
                    comment: "Help: Pull from Keynote section bullet points")
            )
            Divider()
            HelpSection(
                symbol: "gearshape.fill",
                color: Color(.systemGray),
                title: NSLocalizedString(
                    "help.section.setup.title",
                    comment: "Help: Permissions and dependencies section heading"),
                content: NSLocalizedString(
                    "help.section.setup.body",
                    comment: "Help: Permissions and dependencies bullet points")
            )
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 520)
    }
}

private struct HelpSection: View {
    let symbol: String
    let color: Color
    let title: String
    let content: String

    private var bullets: [String] {
        content.components(separatedBy: "\n").compactMap { line in
            let text = line.hasPrefix("• ") ? String(line.dropFirst(2)) : line
            return text.isEmpty ? nil : text
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundColor(color)
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                                .foregroundColor(.secondary)
                            Text(bullet)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.body)
            }
        }
    }
}

#Preview {
    HelpView()
}
