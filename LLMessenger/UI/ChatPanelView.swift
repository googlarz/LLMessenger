// LLMessenger/UI/ChatPanelView.swift
import SwiftUI

struct ChatPanelView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Invisible titlebar spacer — content begins under it
            Spacer().frame(height: 38)

            if let brief = appState.selectedBrief {
                BriefHeaderView(brief: brief)
                Divider().background(Theme.border)
            }

            ThreadView()

            Divider().background(Theme.border)
            ChatInputView()
        }
    }
}
