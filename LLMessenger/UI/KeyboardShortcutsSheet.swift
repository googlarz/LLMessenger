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

    /// Must match the code exactly: ContentView (?, ⌘F, digest J/K), DeskView (⌘1–3),
    /// MainToolbar (⌘[ ⌘] ⌘R ⌥⌘S), BriefProseView (H), ActFeedView (Act keys),
    /// ChatInputView (Ask) and ReplyComposerView (Send/Cancel).
    static let sections: [(title: String, shortcuts: [(key: String, description: String)])] = [
        ("Anywhere", [
            ("⌘1 / ⌘2 / ⌘3",   "Act / Digests / Activity"),
            ("⌘F",             "Search messages"),
            ("⌘R",             "Refresh now"),
            ("⌥⌘S",            "Show or hide the sidebar"),
            ("⌘,",             "Settings"),
            ("? (Shift+/)",    "This help sheet"),
        ]),
        ("Act", [
            ("J / K  ↓ / ↑",   "Select the next / previous item"),
            ("⌘↩",             "Selected item's main button — Send waits 5s; Maybe and high-risk drafts ask first"),
            ("S",              "Skip or dismiss the selected item"),
            ("E",              "Edit the selected draft"),
            ("⌘Z",             "Undo the last send"),
            ("Esc",            "Clear the selection"),
        ]),
        ("Digests", [
            ("J / K  ↓ / ↑",   "Older / newer digest"),
            ("⌘[ / ⌘]",        "Older / newer digest"),
            ("H",              "Mark the first open card done"),
            ("⌘↩",             "Ask (in the Ask box)"),
        ]),
        ("Reply window", [
            ("⌘↩",             "Send — you'll have 5 seconds to undo"),
            ("Esc",            "Cancel — your text is kept"),
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
                    ForEach(Self.sections, id: \.title) { section in
                        sectionHeader(section.title)
                        ForEach(section.shortcuts, id: \.key) { shortcut in
                            shortcutRow(key: shortcut.key, description: shortcut.description)
                        }
                        Spacer().frame(height: 8)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Text("Single keys work in the main window when no text box is focused.")
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            }
        }
        .frame(width: 440, height: 520)
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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(Theme.mono(11, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 104, alignment: .leading)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: Theme.controlRadius)
                        .fill(Theme.surfaceHigh)
                )

            Text(description)
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(.vertical, 4)
    }
}
