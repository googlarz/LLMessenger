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

        if let json = appState.selectedBrief.flatMap({ appState.briefJSON(for: $0) }) {
            let totalMsgs = json.total_messages ?? msgs.count
            let svcs = Set(json.cards.map(\.service)).count
            let briefs = json.cards.count
            let threads = json.total_threads ?? json.cards.reduce(0) { $0 + $1.counts.threads }
            let people = json.total_people ?? json.cards.reduce(0) { $0 + $1.counts.people }
            let highPriority = json.cards.filter { appState.effectivePriority(for: $0) == "high" }.count
            return (totalMsgs, svcs, briefs, threads, people, highPriority, failed)
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
                    // Capped reading measure: past ~760pt the eye has to travel too far to
                    // track a line, and section rules would run wall-to-wall instead of
                    // terminating with the prose. Left-anchored (not centered) so the
                    // ledger's hard left edge stays put — the double .frame is the standard
                    // "cap width, keep leading" idiom inside a full-width ScrollView.
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id("brief-top")
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
                            .id(brief.id)
                            .transition(.opacity)

                            Rule()
                                .padding(.horizontal, Theme.gutter)

                            BriefProseView(
                                brief: brief,
                                messages: briefMessages,
                                canonicalJSON: appState.briefJSON(for: brief)
                            )
                                .id(brief.id)
                                .transition(.opacity)
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
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Theme.bg)
                .onChange(of: appState.selectedBriefID) {
                    // Reset scroll position when navigating to a different brief.
                    DispatchQueue.main.async {
                        proxy.scrollTo("brief-top", anchor: .top)
                    }
                }
                .onChange(of: chatViewModel.threadItems.count) {
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
                .onChange(of: chatViewModel.isLoading) { _, loading in
                    if loading {
                        withAnimation { proxy.scrollTo("loading", anchor: .bottom) }
                    }
                }
            }

            // No footer countdown here — the archive column's "Next digest" line
            // (BriefListView) is the single source for that fact; showing it twice
            // with two different values read as two separate upcoming events.

            // Ask panel — closed by default so reading has one purpose. Opens from
            // the toolbar Ask button; stays open while a conversation is active.
            // Demo/unconfigured states keep their banner (it carries the exit CTA).
            if showComposer {
                Rule()
                ChatInputView()
            }
        }
        // Sync chatViewModel with appState whenever the selected brief changes.
        // Menu-bar and notification paths set selectedBriefID directly without
        // routing through BriefListView, so they must trigger a load here.
        .task(id: appState.selectedBriefID) {
            guard let brief = appState.selectedBrief else { return }
            try? await chatViewModel.loadBrief(brief)
            if brief.status != "open", let id = brief.id {
                appState.markAsOpen(briefID: id)
            }
        }
    }

    private var showComposer: Bool {
        DemoSeeder.isActive
            || !appState.isLLMConfigured
            || appState.askPanelOpen
            || !aiItems.isEmpty
            || chatViewModel.isLoading
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
