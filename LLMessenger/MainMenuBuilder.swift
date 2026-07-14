// LLMessenger/MainMenuBuilder.swift
//
// Programmatic macOS main menu. The app is an accessory/menu-bar app that had
// no main menu at all — so ⌘C/⌘V, ⌘W, and every discoverable command were
// missing whenever the main window was open. The toolbar carries only the
// frequent commands; everything lives here.

import AppKit

@MainActor
enum MainMenuBuilder {
    /// Section switching and sidebar visibility write straight to the same
    /// UserDefaults keys ContentView reads via @AppStorage, so the menu needs
    /// no reference into the SwiftUI tree.
    static func install(appState: AppState, openSettings: @escaping () -> Void) {
        let main = NSMenu()

        // App menu
        let appMenu = NSMenu()
        let appName = "LLMessenger"
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(ClosureMenuItem(title: "Settings…", keyEquivalent: ",") {
            openSettings()
        })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: appName)

        // File
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(ClosureMenuItem(title: "Refresh Now", keyEquivalent: "r") { [weak appState] in
            appState?.onRequestRefresh?()
        })
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: fileMenu, title: "File")

        // Edit — standard responder-chain selectors so text fields work.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(ClosureMenuItem(title: "Find", keyEquivalent: "f") { [weak appState] in
            UserDefaults.standard.set(AppSection.digests.rawValue, forKey: "selectedSection")
            appState?.focusArchiveSearch?()
        })
        main.addItem(submenu: editMenu, title: "Edit")

        // View
        let viewMenu = NSMenu(title: "View")
        for (title, section, key) in [("Act", AppSection.act, "1"),
                                      ("Digests", AppSection.digests, "2"),
                                      ("Activity", AppSection.activity, "3")] {
            viewMenu.addItem(ClosureMenuItem(title: title, keyEquivalent: key) {
                UserDefaults.standard.set(section.rawValue, forKey: "selectedSection")
            })
        }
        viewMenu.addItem(.separator())
        let toggleSidebar = ClosureMenuItem(title: "Show/Hide Sidebar", keyEquivalent: "s") {
            let d = UserDefaults.standard
            d.set(!d.bool(forKey: "sidebarCollapsed"), forKey: "sidebarCollapsed")
        }
        toggleSidebar.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(toggleSidebar)
        viewMenu.addItem(.separator())
        viewMenu.addItem(ClosureMenuItem(title: "Older Digest", keyEquivalent: "[") { [weak appState] in
            appState?.selectAdjacentBrief(newer: false)
        })
        viewMenu.addItem(ClosureMenuItem(title: "Newer Digest", keyEquivalent: "]") { [weak appState] in
            appState?.selectAdjacentBrief(newer: true)
        })
        main.addItem(submenu: viewMenu, title: "View")

        // Window
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(submenu: windowMenu, title: "Window")
        NSApp.windowsMenu = windowMenu

        // Help
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(ClosureMenuItem(title: "LLMessenger Help", keyEquivalent: "?") {
            NSWorkspace.shared.open(URL(string: "https://github.com/googlarz/LLMessenger")!)
        })
        helpMenu.addItem(ClosureMenuItem(title: "Release Notes", keyEquivalent: "") {
            // The changelog lives in the About pane's "What's new" section —
            // this jumps Settings straight there instead of the last-used pane.
            UserDefaults.standard.set(SettingsPane.about.rawValue, forKey: "settings.selectedPane")
            openSettings()
        })
        main.addItem(submenu: helpMenu, title: "Help")
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
    }
}

/// NSMenuItem that runs a closure — avoids scattering @objc targets around.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
