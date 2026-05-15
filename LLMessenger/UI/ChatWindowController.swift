// LLMessenger/UI/ChatWindowController.swift
import AppKit
import SwiftUI

@MainActor
final class ChatWindowController: NSWindowController, NSWindowDelegate {
    private let appState: AppState
    private let chatViewModel: ChatViewModel
    var onRetryService: ((String) -> Void)?

    init(appState: AppState) {
        self.appState = appState
        self.chatViewModel = appState.makeChatViewModel()

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView,
                        .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = "LLMessenger"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.appearance = .dark
        window.backgroundColor = NSColor(Theme.bg)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("LLMessengerMain")
        window.minSize = NSSize(width: 600, height: 420)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = true

        super.init(window: window)
        window.delegate = self

        let content = ContentView(onRetryService: { [weak self] svc in
            guard let self else { return }
            Task { @MainActor in self.onRetryService?(svc) }
        })
            .environmentObject(appState)
            .environmentObject(chatViewModel)
            .environmentObject(appState.contactDirectory)
        window.contentView = NSHostingView(rootView: content)

        appState.contactDirectory.refresh()

        if window.frame.size == NSSize(width: 900, height: 620) {
            window.center()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(selectingBriefID briefID: Int64? = nil) {
        if let id = briefID {
            appState.selectedBriefID = id
        }
        appState.refreshBriefs()
        appState.contactDirectory.refresh()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
