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
            Divider().background(Theme.border)

            HStack(spacing: 0) {
                if !sidebarCollapsed {
                    BriefListView()
                        .frame(width: 240)
                        .background(Theme.sidebar)
                        .transition(.move(edge: .leading).combined(with: .opacity))

                    Divider()
                        .background(Theme.border)
                        .transition(.opacity)
                }

                if appState.selectedBrief != nil {
                    ChatPanelView()
                        .background(Theme.bg)
                } else {
                    EmptyStateView()
                        .background(Theme.bg)
                }

                if showMedia {
                    Divider()
                        .background(Theme.border)
                        .transition(.opacity)

                    MediaPanelView(onClose: { withAnimation(.easeInOut(duration: 0.22)) { showMedia = false } })
                        .frame(width: 260)
                        .background(Theme.sidebar)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(Theme.bg)
        .ignoresSafeArea(.all, edges: .top)
        .animation(.easeInOut(duration: 0.22), value: sidebarCollapsed)
        .animation(.easeInOut(duration: 0.22), value: showMedia)
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.2")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Theme.textTertiary)
            Text("No brief selected")
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)
            Text("Pick a brief from the sidebar")
                .font(.callout)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
