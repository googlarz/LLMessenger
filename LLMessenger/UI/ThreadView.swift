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
        case .userMessage(_, let text):
            UserMessageView(text: text)
        case .assistantResponse(_, let text):
            AssistantResponseView(text: text)
        case .assistantResponseWithSources(_, let text, let sources):
            AssistantResponseWithSourcesView(text: text, sources: sources)
        case .replyDraft(let id, let draft):
            ReplyDraftView(draftID: id, draft: draft)
        case .sendConfirmation(let id, let draft):
            SendConfirmationView(confirmationID: id, draft: draft)
        case .conversationPicker(let id, let req, let opts):
            ConversationPickerView(pickerID: id, originalRequest: req, options: opts)
        }
    }
}

struct LoadingIndicatorView: View {
    @State private var phase = 0

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Theme.textSecondary.opacity(0.5)
                .frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))
                .padding(.vertical, 2)

            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Theme.textTertiary)
                        .frame(width: 4, height: 4)
                        .opacity(phase == i ? 1.0 : 0.3)
                        .scaleEffect(phase == i ? 1.2 : 1.0)
                        .animation(Theme.quick, value: phase)
                }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 380_000_000)
                    phase = (phase + 1) % 3
                }
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 10)
    }
}
