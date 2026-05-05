// LLMessenger/UI/ThreadView.swift
import SwiftUI

struct ThreadView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(chatViewModel.threadItems) { item in
                        threadItemView(item)
                            .id(item.id)
                    }
                    if chatViewModel.isLoading {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Thinking…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .id("loading")
                    }
                }
                .padding(.vertical, 8)
            }
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
    }

    @ViewBuilder
    private func threadItemView(_ item: ThreadItem) -> some View {
        switch item {
        case .message(let m):
            MessageBubbleView(message: m)
        case .assistantResponse(_, let text):
            AssistantResponseView(text: text)
        case .replyDraft(let id, let draft):
            ReplyDraftView(draftID: id, draft: draft)
        }
    }
}
