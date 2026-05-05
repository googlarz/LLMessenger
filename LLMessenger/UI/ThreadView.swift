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
                        LoadingIndicatorView()
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
        .background(Theme.bg)
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

struct LoadingIndicatorView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 2)
                .cornerRadius(1)
                .frame(height: 20)

            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.65)
                    .tint(Theme.accent)
                Text("Thinking…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.accentMuted)
    }
}
