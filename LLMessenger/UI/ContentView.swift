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
        VStack(spacing: 10) {
            if appState.briefs.isEmpty {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(Theme.sans(32, weight: .thin))
                    .foregroundStyle(Theme.textTertiary.opacity(0.5))
                    .padding(.bottom, 4)
                WireLabel("Desk")
                Text("First brief incoming")
                    .font(Theme.display(22))
                    .foregroundStyle(Theme.textSecondary)
                Text("Your messages are being fetched and summarised.")
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            } else {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
