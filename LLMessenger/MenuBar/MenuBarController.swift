// LLMessenger/MenuBar/MenuBarController.swift
import AppKit

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private var unreadCount: Int = 0 { didSet { updateButton() } }
    private var recentBriefs: [Brief] = []

    var onNewBrief: (() -> Void)?
    var onSelectBrief: ((Int64) -> Void)?
    var onOpenSettings: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateButton()
        rebuildMenu()
    }

    func setUnreadCount(_ count: Int) {
        unreadCount = count
    }

    func setBriefs(_ briefs: [Brief]) {
        recentBriefs = Array(briefs.prefix(10))
        rebuildMenu()
    }

    // MARK: - Private

    private func menuPreview(_ summary: String) -> String {
        var text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip markdown code fences
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: #"^```[a-zA-Z]*\n?"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\n?```$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // For JSON briefs, extract the first card headline
        if text.hasPrefix("{") || text.hasPrefix("["),
           let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cards = json["cards"] as? [[String: Any]],
           let first = cards.first,
           let headline = first["headline"] as? String {
            return headline
        }
        // Otherwise use first non-empty line, strip markdown formatting, truncate
        var plain = text.components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? text
        plain = plain
            .replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\*{1,2}([^*]+)\*{1,2}"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return plain.count > 80 ? String(plain.prefix(80)) + "…" : plain
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "envelope.fill", accessibilityDescription: nil)
        button.action = nil   // menu attached, action not used
        button.target = self
        button.title = unreadCount > 0 ? " \(unreadCount)" : ""
        button.imagePosition = unreadCount > 0 ? .imageLeft : .imageOnly
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // New Brief
        let newItem = NSMenuItem(title: "New Brief", action: #selector(newBrief), keyEquivalent: "n")
        newItem.target = self
        menu.addItem(newItem)

        menu.addItem(.separator())

        // Last 10 briefs
        if recentBriefs.isEmpty {
            let empty = NSMenuItem(title: "No briefs yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for brief in recentBriefs {
                let title = brief.notificationText
                let item = NSMenuItem(title: title, action: #selector(briefSelected(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = brief.id
                if brief.status == "ready" {
                    item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
                    item.image?.size = NSSize(width: 8, height: 8)
                }
                // Subtitle via attributed title (truncated)
                if let summary = brief.openingSummary {
                    let preview = menuPreview(summary)
                    let attr = NSMutableAttributedString(string: title + "\n")
                    let sub = NSAttributedString(
                        string: preview,
                        attributes: [.font: NSFont.systemFont(ofSize: 10),
                                     .foregroundColor: NSColor.secondaryLabelColor]
                    )
                    attr.append(sub)
                    item.attributedTitle = attr
                }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        // Settings
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // Quit
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func newBrief() {
        onNewBrief?()
    }

    @objc private func briefSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int64 else { return }
        onSelectBrief?(id)
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }
}
