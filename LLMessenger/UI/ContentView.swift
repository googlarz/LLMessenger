// LLMessenger/UI/ContentView.swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel
    // Brief archive sidebar — toggled by hamburger / ⌥⌘S.
    @State private var sidebarCollapsed = true
    // Desk panel (Now/Waiting/Activity) — shown on the left alongside the brief.
    @State private var deskCollapsed = false
    @State private var showMedia = false
    @State private var showSearch = false
    @State private var showShortcuts = false
    var onRetryService: ((String) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            MainChromeBar(
                sidebarCollapsed: $sidebarCollapsed,
                showMedia: $showMedia,
                showSearch: $showSearch,
                deskCollapsed: $deskCollapsed,
                onRetryService: onRetryService
            )
            Rule()

            HStack(spacing: 0) {
                // Brief archive (power-user drawer, collapsed by default)
                if !sidebarCollapsed {
                    BriefListView()
                        .frame(width: 248)
                        .background(Theme.sidebar)
                        .transition(.move(edge: .leading).combined(with: .opacity))

                    Theme.border.frame(width: Theme.hairline)
                        .transition(.opacity)
                }

                // Desk panel — persistent left sidebar (Inbox/Waiting/Activity)
                if !deskCollapsed {
                    DeskView()
                        .frame(width: 272)
                        .background(Theme.sidebar)
                        .transition(.move(edge: .leading).combined(with: .opacity))

                    Theme.border.frame(width: Theme.hairline)
                        .transition(.opacity)
                }

                // Main content — brief reader (always visible)
                if appState.selectedBrief != nil {
                    ChatPanelView()
                        .background(Theme.bg)
                } else {
                    NoBriefPlaceholder(deskCollapsed: $deskCollapsed)
                        .background(Theme.bg)
                }

                if showMedia {
                    Theme.border.frame(width: Theme.hairline)
                        .transition(.opacity)

                    MediaPanelView(onClose: { withAnimation(Theme.spring) { showMedia = false } })
                        .frame(width: 260)
                        .background(Theme.sidebar)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(Theme.bg)
        .ignoresSafeArea(.all, edges: .top)
        .onChange(of: showSearch) { searching in
            if searching { withAnimation(Theme.spring) { sidebarCollapsed = false } }
        }
        // J/K brief navigation + ? shortcuts overlay
        .background {
            Group {
                Button("") { navigateBriefs(offset: 1) }
                    .keyboardShortcut("j", modifiers: [])
                    .hidden()
                Button("") { navigateBriefs(offset: -1) }
                    .keyboardShortcut("k", modifiers: [])
                    .hidden()
                Button("") { showShortcuts.toggle() }
                    .keyboardShortcut("/", modifiers: .shift)
                    .hidden()
            }
        }
        .sheet(isPresented: $showShortcuts) {
            KeyboardShortcutsSheet(isPresented: $showShortcuts)
        }
        .animation(Theme.spring, value: sidebarCollapsed)
        .animation(Theme.spring, value: deskCollapsed)
        .animation(Theme.spring, value: showMedia)
        // Auto-select the latest brief the first time briefs arrive.
        .onChange(of: appState.briefs.count) { count in
            if appState.selectedBriefID == nil, count > 0 {
                appState.selectedBriefID = appState.briefs
                    .sorted { $0.createdAt > $1.createdAt }
                    .first?.id
            }
        }
    }

    // MARK: - Navigation helpers

    private var briefsNewestFirst: [Brief] {
        appState.briefs.sorted { $0.createdAt > $1.createdAt }
    }

    private func navigateBriefs(offset: Int) {
        let briefs = briefsNewestFirst
        guard !briefs.isEmpty else { return }
        let idx = briefs.firstIndex { $0.id == appState.selectedBriefID } ?? 0
        let target = (idx + offset + briefs.count) % briefs.count
        withAnimation(Theme.quick) { appState.selectedBriefID = briefs[target].id }
    }
}

// MARK: - No-brief placeholder

private struct NoBriefPlaceholder: View {
    @EnvironmentObject var appState: AppState
    @Binding var deskCollapsed: Bool

    var body: some View {
        // First run (never had a brief) → an alive "preparing" skeleton that morphs into the
        // real brief, instead of a dead void. Had-briefs-but-none-open → a quiet "nothing open".
        if appState.briefs.isEmpty {
            FirstBriefPreparingView()
        } else {
            VStack(spacing: 10) {
                Image(systemName: "newspaper")
                    .font(Theme.sans(32, weight: .thin))
                    .foregroundStyle(Theme.textTertiary.opacity(0.5))
                    .padding(.bottom, 4)
                WireLabel("Desk")
                Text("Nothing open")
                    .font(Theme.display(22))
                    .foregroundStyle(Theme.textSecondary)
                Text("Open a brief with J/K, ⌘[ / ⌘], or pick one from the inbox.")
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                if deskCollapsed {
                    Button("Open inbox") {
                        withAnimation(Theme.spring) { deskCollapsed = false }
                    }
                    .buttonStyle(PaperButtonStyle())
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - First-brief preparing state

/// Shown on the very first run while the first brief is being built. A shimmering skeleton
/// of the real brief layout (masthead + two entries) so the moment feels alive and previews
/// what's coming, rather than a black void with one line of text.
private struct FirstBriefPreparingView: View {
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.signal)
                    .frame(width: 6, height: 6)
                    .opacity(pulse ? 1 : 0.25)
                WireLabel("Preparing your first brief", color: Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 22)

            VStack(alignment: .leading, spacing: 0) {
                bar(230, 24)
                bar(300, 11).padding(.top, 12)
                Rule().padding(.vertical, 20)
                ForEach(0..<2, id: \.self) { i in
                    bar(270, 14)
                    bar(440, 10).padding(.top, 9)
                    bar(360, 10).padding(.top, 5)
                    if i == 0 { Rule().padding(.vertical, 18) }
                }
            }
            .opacity(pulse ? 1 : 0.5)
            .animation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true), value: pulse)

            Text("Reading your messages and writing your first brief. This usually takes a moment.")
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 26)

            // The moment a user decides whether to trust this with their messages — say the
            // local-first promise here, not just in PRIVACY.md.
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.ok)
                Text("Everything stays on this Mac. Nothing is sent without your approval.")
                    .font(Theme.sans(11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 30)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { pulse = true }
    }

    private func bar(_ width: CGFloat, _ height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Theme.surfaceHigh)
            .frame(width: width, height: height)
    }
}
