// LLMessenger/UI/Onboarding/OnboardingWindowController.swift
import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    let model: OnboardingModel
    /// Called exactly once: with the outcome the user chose, or `.dismissed`
    /// if the window was closed mid-way.
    var onFinish: ((OnboardingOutcome) -> Void)?
    private var didFinish = false

    init(database: AppDatabase,
         startAt: OnboardingStep = .welcome,
         environment: OnboardingEnvironment = .live(applyChanges: { _ in }),
         defaults: UserDefaults = .standard) {
        model = OnboardingModel(database: database, environment: environment, startAt: startAt, defaults: defaults)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 660),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Follow NSApp.appearance (set from saved theme in AppDelegate).
        window.backgroundColor = NSColor(Theme.bg)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 560)
        // Normal level: a floating window would sit on top of System Settings
        // while the user is trying to grant a permission.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        super.init(window: window)
        window.delegate = self

        model.onFinish = { [weak self] outcome in self?.finish(outcome) }
        window.contentView = NSHostingView(rootView: OnboardingRootView(model: model))
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish(_ outcome: OnboardingOutcome) {
        guard !didFinish else { return }
        didFinish = true
        close()
        onFinish?(outcome)
    }

    func windowWillClose(_ notification: Notification) {
        finish(.dismissed)
    }
}
