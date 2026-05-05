// LLMessenger/UI/ChatPanelView.swift
import SwiftUI

struct ChatPanelView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let brief = appState.selectedBrief {
                BriefHeaderView(brief: brief)
                Divider()
            }

            ThreadView()

            Divider()
            ChatInputView()
        }
    }
}
