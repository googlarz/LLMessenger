// LLMessenger/MenuBar/MenuBarController.swift
import AppKit

// NSObject subclass with no actor isolation so @objc actions fire reliably via ObjC dispatch
private final class MenuActionProxy: NSObject {
    var onNewBrief: (() -> Void)?
    var onLast24h: (() -> Void)?
    var onLast7d: (() -> Void)?
    var onSelectBrief: ((Int64) -> Void)?
    var onOpenSettings: (() -> Void)?

    @objc func newBrief() { onNewBrief?() }
    @objc func last24h() { onLast24h?() }
    @objc func last7d() { onLast7d?() }
    @objc func openSettings() { onOpenSettings?() }
    @objc func briefSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int64 else { return }
        onSelectBrief?(id)
    }
}

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let proxy = MenuActionProxy()
    private var unreadCount: Int = 0 { didSet { updateButton() } }
    private var recentBriefs: [Brief] = []
    private var briefPreviews: [Int64: String] = [:]
    private var isLoading = false
    private var loadingTimer: Timer?
    private var loadingAngle: CGFloat = 0
    private var lastError: String?

    var onNewBrief: (() -> Void)? {
        didSet { proxy.onNewBrief = onNewBrief }
    }
    var onLast24h: (() -> Void)? {
        didSet { proxy.onLast24h = onLast24h }
    }
    var onLast7d: (() -> Void)? {
        didSet { proxy.onLast7d = onLast7d }
    }
    var onSelectBrief: ((Int64) -> Void)? {
        didSet { proxy.onSelectBrief = onSelectBrief }
    }
    var onOpenSettings: (() -> Void)? {
        didSet { proxy.onOpenSettings = onOpenSettings }
    }

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
        briefPreviews = [:]
        for brief in recentBriefs {
            if let id = brief.id, let summary = brief.openingSummary {
                briefPreviews[id] = menuPreview(summary)
            }
        }
        rebuildMenu()
    }

    func setLastError(_ error: String?) {
        lastError = error
        rebuildMenu()
    }

    func setLoading(_ loading: Bool) {
        guard isLoading != loading else { return }
        isLoading = loading
        if loading {
            loadingAngle = 0
            loadingTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tickLoadingAnimation() }
            }
        } else {
            loadingTimer?.invalidate()
            loadingTimer = nil
            updateButton()
        }
        rebuildMenu()
    }

    // MARK: - Private

    private func tickLoadingAnimation() {
        loadingAngle = (loadingAngle + 15).truncatingRemainder(dividingBy: 360)
        guard let button = statusItem.button else { return }
        button.image = rotatedArrow(degrees: loadingAngle)
        button.title = ""
        button.imagePosition = .imageOnly
    }

    private func rotatedArrow(degrees: CGFloat) -> NSImage? {
        guard let base = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil) else { return nil }
        let size = NSSize(width: 16, height: 16)
        let result = NSImage(size: size)
        result.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: -degrees * .pi / 180)
        context.translateBy(x: -size.width / 2, y: -size.height / 2)
        base.draw(in: NSRect(origin: .zero, size: size))
        result.unlockFocus()
        result.isTemplate = true
        return result
    }

    private func menuPreview(_ summary: String) -> String {
        var text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: #"^```[a-zA-Z]*\n?"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\n?```$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasPrefix("{") || text.hasPrefix("["),
           let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cards = json["cards"] as? [[String: Any]],
           let first = cards.first,
           let headline = first["headline"] as? String {
            return headline
        }
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
        button.action = nil
        button.target = self
        button.title = unreadCount > 0 ? " \(unreadCount)" : ""
        button.imagePosition = unreadCount > 0 ? .imageLeft : .imageOnly
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let newTitle = isLoading ? "Refreshing…" : "New Brief"
        let newItem = NSMenuItem(title: newTitle, action: isLoading ? nil : #selector(MenuActionProxy.newBrief), keyEquivalent: isLoading ? "" : "n")
        newItem.target = proxy
        newItem.isEnabled = !isLoading
        menu.addItem(newItem)

        let last24hItem = NSMenuItem(title: "Brief Last 48h", action: isLoading ? nil : #selector(MenuActionProxy.last24h), keyEquivalent: "")
        last24hItem.target = proxy
        last24hItem.isEnabled = !isLoading
        menu.addItem(last24hItem)

        let last7dItem = NSMenuItem(title: "Brief Last 7 Days", action: isLoading ? nil : #selector(MenuActionProxy.last7d), keyEquivalent: "")
        last7dItem.target = proxy
        last7dItem.isEnabled = !isLoading
        menu.addItem(last7dItem)

        if let err = lastError {
            menu.addItem(.separator())
            let errItem = NSMenuItem(title: "⚠ \(err)", action: nil, keyEquivalent: "")
            errItem.isEnabled = false
            menu.addItem(errItem)
        }

        menu.addItem(.separator())

        if recentBriefs.isEmpty {
            let empty = NSMenuItem(title: "No briefs yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for brief in recentBriefs {
                let title = brief.notificationText
                let item = NSMenuItem(title: title, action: #selector(MenuActionProxy.briefSelected(_:)), keyEquivalent: "")
                item.target = proxy
                item.representedObject = brief.id
                if brief.briefStatus == .ready {
                    item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
                    item.image?.size = NSSize(width: 8, height: 8)
                }
                if let id = brief.id, let preview = briefPreviews[id] {
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

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(MenuActionProxy.openSettings), keyEquivalent: ",")
        settingsItem.target = proxy
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }
}
