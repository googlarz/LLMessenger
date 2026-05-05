// LLMessenger/UI/ChatPanelView.swift
import SwiftUI

struct ChatPanelView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel

    private var briefMessages: [Message] {
        chatViewModel.threadItems.compactMap {
            if case .message(let m) = $0 { return m } else { return nil }
        }
    }

    private var aiItems: [ThreadItem] {
        chatViewModel.threadItems.filter {
            if case .message = $0 { return false } else { return true }
        }
    }

    private var headerStats: (messages: Int, services: Int, threads: Int, people: Int) {
        let msgs = briefMessages
        if let summary = appState.selectedBrief?.openingSummary,
           let data = summary.data(using: .utf8),
           let json = try? JSONDecoder().decode(BriefJSON.self, from: data) {
            let totalMsgs = json.total_messages ?? msgs.count
            let svcs = Set(json.cards.map(\.service)).count
            let threads = json.total_threads ?? json.cards.reduce(0) { $0 + $1.counts.threads }
            let people = json.total_people ?? json.cards.reduce(0) { $0 + $1.counts.people }
            return (totalMsgs, svcs, threads, people)
        }
        let svcs = Set(msgs.map(\.service)).count
        let convs = Set(msgs.map(\.conversationId)).count
        let senders = Set(msgs.map(\.sender)).count
        return (msgs.count, svcs, convs, senders)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let brief = appState.selectedBrief {
                            let stats = headerStats
                            BriefHeaderView(
                                brief: brief,
                                messageCount: stats.messages,
                                serviceCount: stats.services,
                                threadCount: stats.threads,
                                peopleCount: stats.people
                            )

                            Divider().background(Theme.border.opacity(0.6))

                            BriefProseView(brief: brief, messages: briefMessages)
                        }

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

            // Footer: countdown + disclaimer
            BriefFooterView()

            Divider().background(Theme.border)
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

// MARK: - Footer

private struct BriefFooterView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Divider().background(Theme.border.opacity(0.4))
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(footerText)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
        }
    }

    private var footerText: String {
        var parts: [String] = []
        if let next = appState.nextPollDate {
            let secs = max(0, Int(next.timeIntervalSinceNow))
            if secs > 0 {
                let m = secs / 60
                let s = secs % 60
                parts.append("Next brief in \(String(format: "%dm %02ds", m, s))")
            }
        }
        parts.append("Summaries are AI-generated and may miss nuance")
        return parts.joined(separator: " · ")
    }
}
