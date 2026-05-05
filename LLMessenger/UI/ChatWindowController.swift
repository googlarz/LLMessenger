// LLMessenger/UI/ChatWindowController.swift
import AppKit
import SwiftUI

@MainActor
final class ChatWindowController {
    private var panel: NSPanel?
    private var eventMonitor: Any?
    private let appState: AppState
    private let chatViewModel: ChatViewModel

    init(appState: AppState) {
        self.appState = appState
        self.chatViewModel = appState.makeChatViewModel()
    }

    func toggle() {
        if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if panel == nil { buildPanel() }
        guard let panel else { return }
        appState.refreshBriefs()
        panel.makeKeyAndOrderFront(nil)
        installEscapeHandler()
        installClickOutsideMonitor()
    }

    func show(selectingBriefID briefID: Int64) {
        appState.selectedBriefID = briefID
        show()
    }

    func hide() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel?.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel?.alphaValue = 1
        }
        removeMonitors()
    }

    // MARK: - Private

    private func buildPanel() {
        guard let screen = NSScreen.main else { return }
        let panelWidth: CGFloat = 380
        let panelHeight = screen.visibleFrame.height
        let origin = CGPoint(x: screen.visibleFrame.maxX - panelWidth,
                             y: screen.visibleFrame.minY)
        let frame = CGRect(origin: origin, size: CGSize(width: panelWidth, height: panelHeight))

        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovable = false

        let contentView = ContentView()
            .environmentObject(appState)
            .environmentObject(chatViewModel)

        p.contentView = NSHostingView(rootView: contentView)
        panel = p
    }

    private func installEscapeHandler() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {  // Escape
                self?.hide()
                return nil
            }
            return event
        }
    }

    private func installClickOutsideMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            if !panel.frame.contains(NSEvent.mouseLocation) {
                Task { @MainActor in self.hide() }
            }
        }
    }

    private func removeMonitors() {
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }
}
