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

    private var headerStats: (messages: Int, services: Int, briefs: Int, threads: Int, people: Int, highPriority: Int, failed: [String]) {
        let msgs = briefMessages
        // Filter out services that are currently healthy. A historical failure
        // at brief-build time (e.g. LLM validation hiccup) shouldn't be advertised
        // as "Signal failed" when Signal is green right now — that scares users
        // into thinking the connection is broken.
        let recordedFailed = decodedStringArray(appState.selectedBrief?.failedServices)
        let failed = recordedFailed.filter { svc in
            let s = appState.serviceHealth[svc]
            return s != nil && s != .ok
        }

        if var summary = appState.selectedBrief?.openingSummary {
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") {
                summary = trimmed
                    .replacingOccurrences(of: #"^```[a-zA-Z]*\n?"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\n?```$"#, with: "", options: .regularExpression)
            }
            if let data = summary.data(using: .utf8),
               let json = try? JSONDecoder().decode(BriefJSON.self, from: data) {
                let totalMsgs = json.total_messages ?? msgs.count
                let svcs = Set(json.cards.map(\.service)).count
                let briefs = json.cards.count
                let threads = json.total_threads ?? json.cards.reduce(0) { $0 + $1.counts.threads }
                let people = json.total_people ?? json.cards.reduce(0) { $0 + $1.counts.people }
                let highPriority = json.cards.filter { $0.priority == "high" }.count
                return (totalMsgs, svcs, briefs, threads, people, highPriority, failed)
            }
        }
        let svcs = Set(msgs.map(\.service)).count
        let convs = Set(msgs.map(\.conversationId)).count
        let senders = Set(msgs.map(\.sender)).count
        return (msgs.count, svcs, convs, convs, senders, 0, failed)
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
                                briefCount: stats.briefs,
                                threadCount: stats.threads,
                                peopleCount: stats.people,
                                highPriorityCount: stats.highPriority,
                                failedServices: stats.failed,
                                generationState: appState.briefGenerationState,
                                errorText: appState.lastError,
                                onRefresh: { appState.onRequestRefresh?() }
                            )

                            Rule()
                                .padding(.horizontal, Theme.gutter)

                            BriefProseView(brief: brief, messages: briefMessages)
                                .id(brief.id)
                        }

                        // Q&A zone — a side conversation about the brief, set apart
                        // by a section label and a faint ink wash, not the brief itself.
                        if !aiItems.isEmpty || chatViewModel.isLoading {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 10) {
                                    WireLabel("Q&A")
                                    Rule()
                                }
                                .padding(.horizontal, Theme.gutter)
                                .padding(.top, 14)
                                .padding(.bottom, 4)

                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(aiItems) { item in
                                        aiItemView(item).id(item.id)
                                    }
                                }
                                .padding(.vertical, 8)

                                if chatViewModel.isLoading {
                                    LoadingIndicatorView()
                                        .id("loading")
                                }
                            }
                            .background(Theme.surface.opacity(0.35))
                            .padding(.top, 8)
                        }
                    }
                }
                .background(Theme.bg)
                .onChange(of: chatViewModel.threadItems.count) { _ in
                    // Delay one run-loop so the new item finishes rendering before scrollTo.
                    DispatchQueue.main.async {
                        if let last = chatViewModel.threadItems.last {
                            // .message items are rendered inside BriefProseView, not in the
                            // LazyVStack below, so their IDs are not registered in this
                            // ScrollViewProxy and scrollTo would silently no-op. Only scroll
                            // for AI thread items (drafts, responses, pickers, etc.).
                            if case .message = last { return }
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
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

            Rule()
            ChatInputView()
        }
        // Sync chatViewModel with appState whenever the selected brief changes.
        // Menu-bar and notification paths set selectedBriefID directly without
        // routing through BriefListView, so they must trigger a load here.
        .task(id: appState.selectedBriefID) {
            guard let brief = appState.selectedBrief else { return }
            try? await chatViewModel.loadBrief(brief)
        }
    }

    @ViewBuilder
    private func aiItemView(_ item: ThreadItem) -> some View {
        switch item {
        case .message:
            EmptyView()
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

    private func decodedStringArray(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return array
    }
}

// MARK: - Footer

private struct BriefFooterView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Rule(color: Theme.border.opacity(0.6))
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(footerText.uppercased())
                .font(Theme.mono(9.5))
                .tracking(1.0)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 7)
        }
    }

    private var footerText: String {
        var parts: [String] = []
        if let next = appState.nextPollDate {
            let secs = max(0, Int(next.timeIntervalSinceNow))
            if secs > 0 {
                let m = secs / 60
                let s = secs % 60
                parts.append("Next brief \(String(format: "%dm %02ds", m, s))")
            }
        }
        parts.append("AI-generated · may miss nuance")
        return parts.joined(separator: "  ·  ")
    }
}
