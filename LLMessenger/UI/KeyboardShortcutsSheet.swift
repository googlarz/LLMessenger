// LLMessenger/UI/KeyboardShortcutsSheet.swift

import SwiftUI

private struct CloseButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovered ? Theme.textSecondary : Theme.textTertiary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(isHovered ? Theme.surface : Theme.surfaceHigh))
        }
        .buttonStyle(.plain)
        .help("Close")
        .animation(Theme.quick, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

struct KeyboardShortcutsSheet: View {
    @Binding var isPresented: Bool

    private let sections: [(title: String, shortcuts: [(key: String, description: String)])] = [
        ("Navigation", [
            ("J / K",          "Older / newer digest"),
            ("⌘[ / ⌘]",        "Older / newer digest"),
            ("⌘F",             "Search messages"),
        ]),
        ("Act queue", [
            ("⌘1",             "Act tab"),
            ("⌘2",             "Digest tab"),
            ("⌘3",             "Activity tab"),
            ("J / K",          "Next / previous action"),
            ("↩ Return",       "Approve selected"),
            ("S",              "Skip selected"),
        ]),
        ("Digest", [
            ("H",              "File the first unhandled card"),
            ("⌘↩",             "Send reply draft"),
        ]),
        ("Window", [
            ("⌘,",             "Settings"),
            ("? (Shift+/)",    "This help sheet"),
        ]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                WireLabel("Keyboard shortcuts")
                Spacer()
                CloseButton { isPresented = false }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Rule()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sections, id: \.title) { section in
                        sectionHeader(section.title)
                        ForEach(section.shortcuts, id: \.key) { shortcut in
                            shortcutRow(key: shortcut.key, description: shortcut.description)
                        }
                        Spacer().frame(height: 8)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 360)
        .background(Theme.bg)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            WireLabel(title.uppercased())
            Spacer()
        }
        .padding(.bottom, 6)
        .padding(.top, 10)
    }

    private func shortcutRow(key: String, description: String) -> some View {
        HStack(spacing: 12) {
            Text(key)
                .font(Theme.mono(11, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 80, alignment: .leading)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: Theme.controlRadius)
                        .fill(Theme.surfaceHigh)
                )

            Text(description)
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.textSecondary)

            Spacer()
        }
        .padding(.vertical, 4)
    }
}
