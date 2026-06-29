// LLMessenger/UI/KeyboardShortcutMonitor.swift
import AppKit
import SwiftUI

/// Scoped key handling for surfaces with keyboard-first workflows.
///
/// SwiftUI `.keyboardShortcut` is still used for visible controls. This monitor is for
/// document-style commands such as J/K navigation where hidden buttons create ambiguous
/// ownership between Desk, Act, and the reader.
struct KeyboardShortcutMonitor: NSViewRepresentable {
    var isEnabled: Bool = true
    let onKeyDown: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onKeyDown = onKeyDown
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onKeyDown: onKeyDown)
    }

    final class Coordinator {
        var isEnabled: Bool
        var onKeyDown: (NSEvent) -> Bool
        private var monitor: Any?

        init(isEnabled: Bool, onKeyDown: @escaping (NSEvent) -> Bool) {
            self.isEnabled = isEnabled
            self.onKeyDown = onKeyDown
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isEnabled else { return event }
                guard !Self.isTextEditing(event.window?.firstResponder) else { return event }
                return self.onKeyDown(event) ? nil : event
            }
        }

        private static func isTextEditing(_ responder: NSResponder?) -> Bool {
            var current = responder
            while let r = current {
                if r is NSTextView || r is NSTextField || r is NSSearchField {
                    return true
                }
                current = r.nextResponder
            }
            return false
        }
    }
}

extension NSEvent {
    var normalizedKey: String {
        (charactersIgnoringModifiers ?? characters ?? "").lowercased()
    }

    var hasCommandOnly: Bool {
        modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
    }

    var hasNoCommandOptionControl: Bool {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        return !flags.contains(.command) && !flags.contains(.option) && !flags.contains(.control)
    }
}
