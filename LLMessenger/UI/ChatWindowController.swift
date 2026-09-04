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

        // An unsent draft or a pending @-mention reply target must not leak
        // from one digest into the next when the user navigates away without
        // sending — this runs on every selectedBriefID change, not just the
        // archive-row-tap path that used to be the only place clearing it.
        let chatViewModel = self.chatViewModel
        appState.onBriefSelectionChanged = { [weak chatViewModel] in
            chatViewModel?.inputText = ""
            chatViewModel?.pendingTarget = nil
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "LLMessenger"
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        // Follow NSApp.appearance (set from saved theme in AppDelegate).
        window.backgroundColor = NSColor(Theme.bg)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("LLMessengerMain")
        window.minSize = NSSize(width: 860, height: 520)
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
        // NSHostingController (not NSHostingView) so SwiftUI .toolbar and
        // .navigationTitle bridge into the window's native NSToolbar/title bar.
        let restoredFrame = window.frame
        let hostingController = NSHostingController(rootView: content)
        hostingController.view.setAccessibilityLabel("LLMessenger main window")
        window.contentViewController = hostingController
        // Assigning contentViewController resizes to the content's ideal size;
        // put the autosaved frame back.
        window.setFrame(restoredFrame, display: false)

        appState.contactDirectory.refresh()

        if window.frame.size == NSSize(width: 1040, height: 700) {
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
