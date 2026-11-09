// LLMessenger/UI/Onboarding/MenuBarHint.swift
//
// LLMessenger has no Dock icon. These pieces tell the user where it went.
import AppKit
import SwiftUI

/// The menu-bar icon, drawn the same way MenuBarController draws it:
/// three typeset lines, the last one short.
struct MenuBarGlyph: View {
    var color: Color = Theme.textPrimary
    var scale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 2.6 * scale) {
            bar(12)
            bar(12)
            bar(7.5)
        }
        .frame(width: 16 * scale, height: 16 * scale, alignment: .leading)
        .accessibilityHidden(true)
    }

    private func bar(_ width: CGFloat) -> some View {
        Capsule().fill(color).frame(width: width * scale, height: 1.7 * scale)
    }
}

/// "Look for this icon" line used on the welcome and last steps.
struct MenuBarLocationNote: View {
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            MenuBarGlyph(color: Theme.textSecondary, scale: 1.1)
                .padding(5)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border, lineWidth: Theme.hairline))
            Text("LLMessenger lives in your menu bar, not the Dock. Look for this icon at the top of your screen.")
                .font(Theme.sans(11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MenuBarHintView: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 9))
                .foregroundStyle(Theme.border)
            HStack(spacing: 12) {
                MenuBarGlyph(scale: 1.3)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Still here, in your menu bar")
                        .font(Theme.display(14))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Closing this window doesn\u{2019}t quit LLMessenger. Click the icon any time.")
                        .font(Theme.sans(11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, lineWidth: Theme.hairline))
        }
        .padding(8)
    }
}

/// Shown once, the first time the main window is closed.
@MainActor
enum MenuBarHint {
    private static var panel: NSPanel?

    static func showOnceIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: OnboardingFlag.menuBarHintKey) else { return }
        defaults.set(true, forKey: OnboardingFlag.menuBarHintKey)
        show()
    }

    static func show() {
        let host = NSHostingView(rootView: MenuBarHintView())
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Point at the real status item when AppKit exposes its window; otherwise
        // sit under the right end of the menu bar, where status items live.
        let statusWindow = NSApp.windows.first { String(describing: type(of: $0)).contains("StatusBar") }
        let screen = (statusWindow?.screen ?? NSScreen.main)?.frame ?? .zero
        let anchorX = statusWindow?.frame.midX ?? (screen.maxX - 120)
        let topY = statusWindow?.frame.minY ?? (screen.maxY - 24)
        let x = min(max(anchorX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: topY - size.height))

        self.panel?.close()
        self.panel = panel
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak panel] in
            guard let panel, MenuBarHint.panel === panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 },
                                                 completionHandler: { panel.close() })
        }
    }
}
