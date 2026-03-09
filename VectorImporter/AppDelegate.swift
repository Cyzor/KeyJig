import Cocoa
import SwiftUI
import WebKit

class MainWindowController: NSWindowController, NSWindowDelegate {
    convenience init(contentView: ContentView, statusBarItem: NSStatusItem?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.isReleasedWhenClosed = false
        window.level = .normal
        window.title = "Vector Importer"

        self.init(window: window)

        self.window?.delegate = self
        self.window?.contentViewController = NSHostingController(rootView: contentView)
        self.window?.setFrameAutosaveName("VectorImporterFloatingWindow")

        // Set minimum and maximum window sizes
        // Minimum: ~380x480 (current default size)
        // Maximum: ~900x1200 (reasonable desktop workspace)
        window.minSize = NSSize(width: 320, height: 380)
        window.maxSize = NSSize(width: 900, height: 1200)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Remove from floating windows list when closed
        if let appDelegate = AppDelegate.shared {
            appDelegate.floatingWindows.removeAll { $0 === self }
        }
    }
}

// MARK: - App Menu Setup

class AppMenu {
    static func setupMenuBar() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItemName = NSLocalizedString("VectorImporter", comment: "")
        let appMenuItem = mainMenu.addItem(
            withTitle: appMenuItemName, action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: appMenuItemName)

        appMenu.addItem(
            withTitle: "About VectorImporter", action: #selector(AppDelegate.showAbout),
            keyEquivalent: "")
        //        appMenu.addItem(NSMenuItem.separator())
        //        appMenu.addItem(
        //            withTitle: "Preferences...", action: #selector(AppDelegate.showPreferences),
        //            keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Hide VectorImporter", action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        appMenu.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "")
        appMenu.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit VectorImporter", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        appMenuItem.submenu = appMenu

        // File Menu
        let fileMenuItem = mainMenu.addItem(withTitle: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")

        fileMenu.addItem(
            withTitle: "Show Menubar Panel", action: #selector(AppDelegate.showPanel),
            keyEquivalent: "n"
        )
        fileMenu.addItem(
            withTitle: "New Viewer", action: #selector(AppDelegate.newFloatingWindow),
            keyEquivalent: "N"
        ).keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(
            withTitle: "Open SVG File…", action: #selector(AppDelegate.openSVGFile),
            keyEquivalent: "o"
        )
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(
            withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        fileMenuItem.submenu = fileMenu

        // Edit Menu
        let editMenuItem = mainMenu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")

        editMenu.addItem(
            withTitle: "Undo", action: nil, keyEquivalent: "z")
        editMenu.addItem(
            withTitle: "Redo", action: nil, keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(
            withTitle: "Cut", action: nil, keyEquivalent: "x")
        editMenu.addItem(
            withTitle: "Copy", action: nil, keyEquivalent: "c")
        editMenu.addItem(
            withTitle: "Paste", action: nil, keyEquivalent: "v")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(
            withTitle: "Clear", action: #selector(AppDelegate.clearSVG), keyEquivalent: "")

        editMenuItem.submenu = editMenu

        // Help Menu
        let helpMenuItem = mainMenu.addItem(withTitle: "Help", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "Help")

        helpMenu.addItem(
            withTitle: "VectorImporter Help", action: #selector(AppDelegate.showHelp),
            keyEquivalent: "?")

        helpMenuItem.submenu = helpMenu

        NSApplication.shared.mainMenu = mainMenu
    }
}

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    static var shared: AppDelegate?

    var popover: NSPopover?
    var statusBarItem: NSStatusItem?
    var floatingWindows: [MainWindowController] = []
    var windowCascadeOffset: Int = 0

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        AppDelegate.shared = self

        // Set as delegate for Dock menu FIRST, before any other setup
        NSApplication.shared.delegate = self

        // Set up the menu bar
        AppMenu.setupMenuBar()

        // Create the popover
        let contentView = ContentView()
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 480, height: 680)
        popover.contentViewController = NSHostingController(rootView: contentView)
        popover.behavior = .transient
        self.popover = popover

        // Set up status bar icon
        self.statusBarItem = NSStatusBar.system.statusItem(
            withLength: CGFloat(NSStatusItem.variableLength))

        if let button = self.statusBarItem?.button {
            if let iconImage = NSImage(named: "Icon") {
                iconImage.size = NSSize(width: 18, height: 18)
                iconImage.isTemplate = true
                button.image = iconImage
            }
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Check clipboard for SVG on launch
        checkAndLoadClipboardSVG()

        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        guard let popover = self.popover else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            if let statusBarButton = self.statusBarItem?.button {
                popover.show(
                    relativeTo: statusBarButton.bounds, of: statusBarButton,
                    preferredEdge: NSRectEdge.minY)
                // Check clipboard when popover is shown
                checkAndLoadClipboardSVG()
            }
        }
    }

    private func checkAndLoadClipboardSVG() {
        let svg = convertClipboardToSVG()
        if !svg.isEmpty && svg != AppState.shared.svgString {
            AppState.shared.svgString = svg
        }
    }

    @objc func showPanel() {
        checkAndLoadClipboardSVG()
        togglePopover(nil)
    }

    @objc func newFloatingWindow() {
        let contentView = ContentView()
        let windowController = MainWindowController(
            contentView: contentView, statusBarItem: self.statusBarItem)

        // Check clipboard before showing new window
        checkAndLoadClipboardSVG()

        // Position the new window with cascading offset
        if let screenFrame = NSScreen.main?.frame {
            let cascadeAmount = 20
            let x = screenFrame.midX - 200 + CGFloat(windowCascadeOffset * cascadeAmount)
            let y = screenFrame.midY - 260 - CGFloat(windowCascadeOffset * cascadeAmount)
            windowController.window?.setFrame(
                NSRect(x: x, y: y, width: 400, height: 520), display: true)

            // Increment offset for next window, reset if it gets too large
            windowCascadeOffset += 1
            if windowCascadeOffset > 10 {
                windowCascadeOffset = 0
            }
        }

        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        floatingWindows.append(windowController)
    }

    @objc func openSVGFile() {
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
                    let svgContent = try String(contentsOf: result, encoding: .utf8)
                    AppState.shared.svgString = svgContent
                } catch {
                    NSLog("Error reading file: \(error)")
                }
            }
        }
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Vector Importer"
        alert.informativeText = """
            A utility for converting vector graphics to Keynote-compatible formats.

            Version 1.1

            Copyright © 2021 Jonathan Lampérth

            The Noun Project licensed under CC-BY-3.0 US:
            https://thenounproject.com/legal/terms-of-use/#icon-licenses
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Noted")
        alert.runModal()
    }

    @objc func clearSVG() {
        AppState.shared.svgString = ""
        AppState.shared.svgURL = ""
    }

    @objc func showPreferences() {
        let alert = NSAlert()
        alert.messageText = "Preferences"
        alert.informativeText = "Preferences coming soon!"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Help"
        alert.informativeText = """
            Vector Importer helps you convert and import vector graphics into Keynote.

            Features:
            • Convert SVG files for use in Keynote
            • Bridge clipboard content between design tools
            • Support for Inkscape PDF fallback conversion

            Click the menu bar icon to show/hide the panel, or use File > New Floating Window to open a draggable window.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        // Handle clicking the dock icon
        if !flag {
            togglePopover(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Allow app to continue running when last window closes (menu bar stays active)
        return false
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        // Check clipboard when app is reactivated
        checkAndLoadClipboardSVG()
    }

    // MARK: - Dock Menu

    @objc func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Show Panel", action: #selector(showPanel), keyEquivalent: "")
        menu.addItem(
            withTitle: "New Viewer", action: #selector(newFloatingWindow), keyEquivalent: "")
        return menu
    }
}
