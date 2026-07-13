// LLMessenger/UI/Settings/SettingsWindowController.swift
import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private let database: AppDatabase
    private let paneSelection = SettingsPaneSelection()
    private var paneObservation: AnyCancellable?
    var onRunSetup: (() -> Void)?
    var onBuild7DaySummaries: (() async -> Void)?
    var onSyncContacts: (() async -> Void)?
    var onRetryService: ((String) async -> Void)?
    var onScheduleChanged: (() -> Void)?

    init(database: AppDatabase) {
        self.database = database

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = paneSelection.pane.title
        window.toolbarStyle = .preference
        // Follow NSApp.appearance (set from saved theme in AppDelegate).
        window.backgroundColor = NSColor(Theme.bg)
        window.isReleasedWhenClosed = false
        // Must be able to appear over another app's fullscreen Space. A managed window
        // (the default) can't be placed on a fullscreen Space, so ordering it front from
        // there forces a broken Space transition that hangs/crashes the app. Matches
        // ChatWindowController.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "LLMessengerSettingsToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = toolbarIdentifier(for: paneSelection.pane)
        window.toolbar = toolbar

        // contentView set after super.init so we can capture self
        window.contentView = NSHostingView(rootView: SettingsView(
            database: database,
            onRunSetup: { [weak self] in self?.onRunSetup?() },
            onBuild7DaySummaries: { [weak self] in await self?.onBuild7DaySummaries?() },
            onSyncContacts: { [weak self] in await self?.onSyncContacts?() },
            onRetryService: { [weak self] svc in await self?.onRetryService?(svc) },
            onScheduleChanged: { [weak self] in self?.onScheduleChanged?() },
            selection: paneSelection
        ))

        paneObservation = paneSelection.$pane
            .sink { [weak self] pane in
                self?.window?.title = pane.title
                self?.window?.toolbar?.selectedItemIdentifier = self?.toolbarIdentifier(for: pane)
            }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible == false { window?.center() }
        showWindow(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(toolbarIdentifier)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(toolbarIdentifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(toolbarIdentifier)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = pane(for: itemIdentifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.paletteLabel = pane.title
        item.toolTip = "\(pane.title) settings"
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(selectPane(_:))
        item.tag = pane.rawValue
        return item
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        guard let pane = SettingsPane(rawValue: sender.tag) else { return }
        paneSelection.pane = pane
    }

    private func toolbarIdentifier(for pane: SettingsPane) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("com.llmessenger.settings.\(pane.rawValue)")
    }

    private func pane(for identifier: NSToolbarItem.Identifier) -> SettingsPane? {
        SettingsPane.allCases.first { toolbarIdentifier(for: $0) == identifier }
    }
}
