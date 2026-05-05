// LLMessenger/UI/ContentView.swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            BriefListView()
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 300)
                .background(Theme.sidebar)

            Divider()
                .background(Theme.border)

            // Main content
            if appState.selectedBrief != nil {
                ChatPanelView()
                    .background(Theme.bg)
            } else {
                EmptyStateView()
                    .background(Theme.bg)
            }
        }
        .background(Theme.bg)
        // Extends behind the invisible titlebar
        .ignoresSafeArea(.all, edges: .top)
    }
}

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
