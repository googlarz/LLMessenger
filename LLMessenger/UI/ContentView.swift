// LLMessenger/UI/ContentView.swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel
    @State private var sidebarCollapsed = false
    @State private var showMedia = false

    var body: some View {
        VStack(spacing: 0) {
            ContentHeaderBar(sidebarCollapsed: $sidebarCollapsed, showMedia: $showMedia)
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

// MARK: - Header bar (sits in the invisible titlebar area)

private struct ContentHeaderBar: View {
    @EnvironmentObject var appState: AppState
    @Binding var sidebarCollapsed: Bool
    @Binding var showMedia: Bool

    var body: some View {
        ZStack {
            Theme.sidebar

            HStack(spacing: 0) {
                // Space for macOS traffic lights (~70pt from left edge)
                Spacer().frame(width: 72)

                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { sidebarCollapsed.toggle() }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Toggle sidebar")

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { showMedia.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 11))
                        Text("Media")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(showMedia ? Theme.surfaceHigh : Color.clear)
                    .foregroundStyle(showMedia ? Theme.textPrimary : Theme.textTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(showMedia ? Theme.border : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .padding(.trailing, 14)
            }

            // Centered title — non-interactive
            HStack {
                Spacer()
                Text(titleText)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
                Spacer()
            }
            .allowsHitTesting(false)
        }
        .frame(height: 38)
    }

    private var titleText: String {
        guard let brief = appState.selectedBrief else { return "LLMessenger" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let end = brief.createdAt
        let start = end.addingTimeInterval(-3600)
        return "LLMessenger — \(f.string(from: start)) – \(f.string(from: end))"
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
