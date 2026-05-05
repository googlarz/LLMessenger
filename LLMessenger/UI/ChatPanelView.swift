// LLMessenger/UI/ChatPanelView.swift
import SwiftUI

struct ChatPanelView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel

    // Messages from the thread (excluding AI items)
    private var briefMessages: [Message] {
        chatViewModel.threadItems.compactMap {
            if case .message(let m) = $0 { return m } else { return nil }
        }
    }

    // AI responses + reply drafts only
    private var aiItems: [ThreadItem] {
        chatViewModel.threadItems.filter {
            if case .message = $0 { return false } else { return true }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Invisible titlebar spacer
            Spacer().frame(height: 38)

            // Scrollable content: brief prose + AI thread
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Brief header with AI summary bar
                        if let brief = appState.selectedBrief {
                            BriefHeaderView(brief: brief)

                            Divider().background(Theme.border.opacity(0.6))

                            // Flowing prose: source filter + summary + blockquote quotes
                            BriefProseView(brief: brief, messages: briefMessages)
                        }

                        // AI conversation items (responses + drafts)
                        if !aiItems.isEmpty {
                            Divider()
                                .background(Theme.border.opacity(0.5))
                                .padding(.horizontal, 28)

                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(aiItems) { item in
                                    aiItemView(item).id(item.id)
                                }
                            }
                            .padding(.vertical, 8)
                        }

                        if chatViewModel.isLoading {
                            LoadingIndicatorView()
                                .id("loading")
                        }
                    }
                }
                .background(Theme.bg)
                .onChange(of: chatViewModel.threadItems.count) { _ in
                    if let last = chatViewModel.threadItems.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: chatViewModel.isLoading) { loading in
                    if loading {
                        withAnimation { proxy.scrollTo("loading", anchor: .bottom) }
                    }
                }
            }

            Divider().background(Theme.border)

            // Always-visible composer
            ChatInputView()
        }
    }

    @ViewBuilder
    private func aiItemView(_ item: ThreadItem) -> some View {
        switch item {
        case .message:
            EmptyView()
        case .assistantResponse(_, let text):
            AssistantResponseView(text: text)
        case .replyDraft(let id, let draft):
            ReplyDraftView(draftID: id, draft: draft)
        }
    }
}
