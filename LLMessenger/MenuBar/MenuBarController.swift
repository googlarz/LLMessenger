// LLMessenger/MenuBar/MenuBarController.swift
import AppKit

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private var unreadCount: Int = 0 {
        didSet { updateButton() }
    }
    private var serviceHealthStatus: [String: AdapterHealthResult.Status] = [:]
    var onTogglePanel: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateButton()
        buildMenu()
    }

    func setUnreadCount(_ count: Int) {
        unreadCount = count
    }

    func setServiceHealth(_ health: AdapterHealthResult.Status, for service: String) {
        serviceHealthStatus[service] = health
        rebuildServiceItems()
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let icon = NSImage(systemSymbolName: "envelope.fill", accessibilityDescription: nil)
        button.image = icon
        button.action = #selector(buttonClicked)
        button.target = self

        if unreadCount > 0 {
            button.title = " \(unreadCount)"
            button.imagePosition = .imageLeft
        } else {
            button.title = ""
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open LLMessenger",
                                  action: #selector(openApp),
                                  keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func rebuildServiceItems() {
        // Expanded in Plan 4 (Settings) to show per-service health dots
    }

    @objc private func buttonClicked() {
        onTogglePanel?()
    }

    @objc private func openApp() {
        onTogglePanel?()
    }

    @objc private func openSettings() {
        // Implemented in Plan 4
    }
}
