import AppKit

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private var unreadCount: Int = 0 {
        didSet { updateButton() }
    }

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateButton()
        buildMenu()
    }

    func setUnreadCount(_ count: Int) {
        unreadCount = count
    }

    func setServiceHealth(_ health: AdapterHealthResult.Status, for service: String) {
        rebuildServiceItems()
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let icon = NSImage(systemSymbolName: "envelope.fill", accessibilityDescription: nil)
        button.image = icon

        if unreadCount > 0 {
            button.title = " \(unreadCount)"
            button.imagePosition = .imageLeft
        } else {
            button.title = ""
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open LLMessenger",
                                action: #selector(openApp),
                                keyEquivalent: "o"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…",
                                action: #selector(openSettings),
                                keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    private func rebuildServiceItems() {
        // Expanded in Plan 4 (Settings) to show per-service health dots
    }

    @objc private func openApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettings() {
        // Implemented in Plan 4
    }
}
