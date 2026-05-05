// LLMessenger/UI/ContentView.swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel

    var body: some View {
        HSplitView {
            BriefListView()
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 240)

            if appState.selectedBrief != nil {
                ChatPanelView()
            } else {
                Text("Select a brief")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}
