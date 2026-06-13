// LLMessenger/UI/ContentView.swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel
    // Default to collapsed — the user said "we don't need many briefs in sidebar".
    // The new chrome bar carries a brief-picker popover so this drawer is just an
    // escape hatch for power users (toggle via the hamburger or ⌥⌘S).
    @State private var sidebarCollapsed = true
    @State private var showMedia = false
    @State private var showSearch = false
    var onRetryService: ((String) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            MainChromeBar(
                sidebarCollapsed: $sidebarCollapsed,
                showMedia: $showMedia,
                showSearch: $showSearch,
                onRetryService: onRetryService
            )
            Rule()

            HStack(spacing: 0) {
                if !sidebarCollapsed {
                    BriefListView()
                        .frame(width: 248)
                        .background(Theme.sidebar)
                        .transition(.move(edge: .leading).combined(with: .opacity))

                    Theme.border.frame(width: Theme.hairline)
                        .transition(.opacity)
                }

                if appState.selectedBrief != nil {
                    ChatPanelView()
                        .background(Theme.bg)
                } else {
                    DeskView()
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
        .animation(Theme.spring, value: sidebarCollapsed)
        .animation(Theme.spring, value: showMedia)
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 10) {
            WireLabel("Nothing selected")
            Text("The desk is clear.")
                .font(Theme.display(21))
                .foregroundStyle(Theme.textSecondary)
            Text("Pick a brief from the archive, or wait for the next round.")
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
