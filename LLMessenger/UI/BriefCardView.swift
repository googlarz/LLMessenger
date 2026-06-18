// LLMessenger/UI/BriefCardView.swift
//
// A single brief card, typeset as an editorial entry: margin rule for
// priority, stamp metadata line, serif headline, prose, em-dash action list,
// and evidence rendered as citations. No boxes — entries are separated by
// hairline rules in the parent.

import SwiftUI

// MARK: - Priority stamp

struct PriorityStamp: View {
    let priority: String

    var body: some View {
        Text(label)
            .font(Theme.mono(11, weight: .bold))
            .tracking(1.1)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(color.opacity(priority == "high" ? 0.7 : 0.45), lineWidth: 1)
            )
    }

    private var label: String {
        switch priority {
        case "high": return "NEEDS YOU"
        case "med":  return "HEADS-UP"
        default:     return "FYI"
        }
    }

    private var color: Color {
        switch priority {
        case "high": return Theme.signal
        case "med":  return Theme.standby
        default:     return Theme.textTertiary
        }
    }
}

// MARK: - Card

struct BriefCardView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel

    let number: Int
    let card: BriefCard
    let briefID: Int64?
    /// Batch-fetched by the parent — a per-card DB read here ran on every
    /// hover transition (PERF-2026-06-12 #1).
    let conversationContext: ConversationContext?
    let onShowTimeline: (String, String, String) -> Void
    /// When true, the card renders expanded by default even if not high priority.
    /// Used to promote the lead med card when no high cards exist in the brief.
    var promoted: Bool = false

    @State private var bodyExpanded = false
    @State private var evidenceExpanded = false
    @State private var showLabelEditor = false
    @State private var labelEditText = ""
    @State private var labelEditHint = "auto"
    @State private var hovering = false
    @State private var labelHovered = false
    @State private var chevronHovered = false
    /// Set on save so the stamp updates immediately; the parent's batch
    /// cache refreshes on the next brief change.
    @State private var savedContextOverride: ConversationContext?

    private var effectiveContext: ConversationContext? {
        savedContextOverride ?? conversationContext
    }

    private var isHigh: Bool { card.priority == "high" }
    private var isBodyExpanded: Bool { isHigh || promoted || bodyExpanded }
    private var isHandled: Bool {
        guard let briefID else { return false }
        return appState.isCardHandled(briefID: briefID, cardID: card.id)
    }
    private var convName: String { card.conversation ?? Theme.serviceName(card.service) }

    private var displayHeadline: String {
        let h = card.headline
        // Match the LLM's empty/placeholder sentinel exactly — a hasPrefix("none")
        // check would swallow real headlines like "None of us can make Friday".
        let norm = h.trimmingCharacters(in: .whitespaces).lowercased()
        guard h.isEmpty || norm == "none" || norm == "none." else { return h }
        let s = String(card.summary.prefix(80))
        return s.isEmpty ? convName : s
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Margin rule — the galley-proof redline.
            // Vermilion: high priority. Muted ink: promoted lede. Clear: everything else.
            (isHigh && !isHandled    ? Theme.signal :
             promoted && !isHandled  ? Theme.textTertiary.opacity(0.35) :
             Color.clear)
                .frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))
                .padding(.trailing, Theme.gutter - 12)

            VStack(alignment: .leading, spacing: 9) {
                stampRow
                headline

                if isBodyExpanded {
                    expandedBody
                }
            }
            .padding(.trailing, Theme.gutter)
        }
        .padding(.leading, 10)
        .padding(.vertical, isHigh || isBodyExpanded ? 14 : 8)
        .background(hovering && !isBodyExpanded ? Theme.surface.opacity(0.5) : Color.clear)
        .opacity(isHandled ? 0.45 : 1)
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
    }

    // MARK: - Stamp row (always visible)

    private var stampRow: some View {
        HStack(spacing: 8) {
            Text(String(format: "%02d", number))
                .font(Theme.mono(11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)

            ServiceStamp(service: card.service, size: 18)

            Button {
                labelEditText = effectiveContext?.label ?? ""
                labelEditHint = effectiveContext?.priorityHint ?? "auto"
                showLabelEditor = true
            } label: {
                HStack(spacing: 6) {
                    Text(convName.uppercased())
                        .font(Theme.mono(10.5, weight: .semibold))
                        .tracking(1.0)
                        .foregroundStyle(isHandled ? Theme.textTertiary : (labelHovered ? Theme.textPrimary : Theme.textSecondary))
                        .lineLimit(1)
                    if let lbl = effectiveContext?.label, !lbl.isEmpty {
                        Text(lbl.uppercased())
                            .font(Theme.mono(11, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(labelHovered ? Theme.textSecondary : Theme.textTertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Add a label or priority hint for this conversation")
            .animation(Theme.quick, value: labelHovered)
            .onHover { labelHovered = $0 }
            .popover(isPresented: $showLabelEditor) {
                LabelEditorPopover(
                    convName: convName,
                    label: $labelEditText,
                    priorityHint: $labelEditHint,
                    onSave: {
                        let label = labelEditText.trimmingCharacters(in: .whitespaces)
                        appState.saveConversationContext(
                            service: card.service,
                            conversationId: card.conversationId,
                            label: label,
                            priorityHint: labelEditHint
                        )
                        savedContextOverride = ConversationContext(
                            service: card.service, conversationId: card.conversationId,
                            label: label, priorityHint: labelEditHint, updatedAt: Date())
                        showLabelEditor = false
                    },
                    onCancel: { showLabelEditor = false }
                )
            }

            Button {
                onShowTimeline(card.service, card.conversationId, convName)
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary.opacity(hovering ? 1 : 0))
            }
            .buttonStyle(.plain)
            .help("Full conversation history across briefs")

            Spacer(minLength: 8)

            if card.counts.messages > 1 {
                Text("\(card.counts.messages)M · \(card.counts.people)P")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textTertiary)
            }

            if isHandled {
                WireLabel("Filed", color: Theme.ok)
            } else {
                Menu {
                    Text("Correct priority — teaches future briefs")
                    ForEach(["high", "med", "low"], id: \.self) { p in
                        Button(p.capitalized) {
                            appState.savePriorityCorrection(
                                service: card.service, conversationId: card.conversationId,
                                headline: card.headline, llmPriority: card.priority, userPriority: p)
                        }
                    }
                } label: {
                    PriorityStamp(priority: card.priority)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Tap to correct this priority")
            }

            // High and promoted cards are always-expanded ledes — no collapse affordance.
            if !isHigh && !promoted {
                Button {
                    withAnimation(Theme.spring) { bodyExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(chevronHovered ? Theme.textSecondary : Theme.textTertiary)
                        .rotationEffect(.degrees(isBodyExpanded ? 180 : 0))
                }
                .buttonStyle(.plain)
                .help(isBodyExpanded ? "Collapse" : "Expand")
                .accessibilityLabel(isBodyExpanded ? "Collapse details" : "Expand details")
                .animation(Theme.quick, value: chevronHovered)
                .onHover { chevronHovered = $0 }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isHigh && !promoted else { return }
            withAnimation(Theme.spring) { bodyExpanded.toggle() }
        }
    }

    private var headline: some View {
        Text(displayHeadline)
            .font(Theme.display(isBodyExpanded ? 17 : 14.5))
            .foregroundStyle(isHandled ? Theme.textTertiary : Theme.textPrimary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isHigh && !promoted else { return }
                withAnimation(Theme.spring) { bodyExpanded.toggle() }
            }
    }

    // MARK: - Expanded body

    @ViewBuilder
    private var expandedBody: some View {
        Text(card.summary)
            .font(Theme.bodyFont)
            .foregroundStyle(Theme.textPrimary.opacity(isHandled ? 0.55 : 0.88))
            .lineSpacing(4.5)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)

        if let callback = card.callback, !callback.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Text("↩")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textTertiary)
                Text(callback)
                    .font(Theme.sans(12.5))
                    .italic()
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 1)
        }

        if !card.actions.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(card.actions, id: \.self) { action in
                    HStack(alignment: .top, spacing: 8) {
                        Text("—")
                            .font(Theme.mono(12, weight: .semibold))
                            .foregroundStyle(isHandled ? Theme.textTertiary : Theme.signal)
                        Text(action)
                            .font(Theme.sans(13, weight: .medium))
                            .foregroundStyle(Theme.textPrimary.opacity(isHandled ? 0.55 : 1))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 3)
        }

        actionBar
            .padding(.top, 4)

        if evidenceExpanded {
            if let briefID {
                BriefCardEvidenceView(card: card, briefID: briefID, repository: appState.repository)
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Text("Evidence unavailable — brief not yet persisted.")
                    .font(Theme.sans(12))
                    .italic()
                    .foregroundStyle(Theme.textTertiary)
            }
        }

        QuickReplyRow(card: card)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 2) {
            Button {
                withAnimation(Theme.spring) {
                    evidenceExpanded.toggle()
                    if evidenceExpanded {
                        InstrumentationManager.shared.track(event: .sourceExpanded,
                            metadata: ["cardID": card.id, "conversationID": card.conversationId])
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text("\(card.sourceMessageIds.count) \(card.sourceMessageIds.count == 1 ? "SOURCE" : "SOURCES")")
                    if !card.quotes.isEmpty {
                        Text("· \(card.quotes.count)Q")
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .rotationEffect(.degrees(evidenceExpanded ? 180 : 0))
                }
            }
            .buttonStyle(WireActionStyle(tint: evidenceExpanded ? Theme.textPrimary : Theme.textTertiary))
            .help(evidenceExpanded ? "Hide the source messages" : "Show the source messages behind this card")

            divider

            Button(card.counts.messages > 20 ? "CATCH ME UP" : "DETAIL") {
                Task {
                    await chatViewModel.askForDetails(
                        service: card.service,
                        conversationID: card.conversationId,
                        displayName: card.conversation ?? "",
                        headline: card.counts.messages > 20
                            ? "Give me the full arc — what's been going on in this thread?"
                            : card.headline
                    )
                }
            }
            .buttonStyle(WireActionStyle())
            .help(card.counts.messages > 20 ? "Deeper summary of this long thread" : "Ask for more detail")

            divider

            Button("REPLY") {
                chatViewModel.prepareReply(
                    service: card.service,
                    conversationID: card.conversationId,
                    displayName: card.conversation ?? ""
                )
            }
            .buttonStyle(WireActionStyle())
            .help("Draft a reply")

            Spacer(minLength: 0)

            Button {
                guard let briefID else { return }
                withAnimation(Theme.quick) {
                    if isHandled {
                        appState.unmarkCardHandled(briefID: briefID, cardID: card.id)
                    } else {
                        appState.markCardHandled(briefID: briefID, cardID: card.id)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isHandled ? "arrow.uturn.left" : "checkmark")
                        .font(.system(size: 9, weight: .bold))
                    Text(isHandled ? "REOPEN" : "FILE")
                }
            }
            .buttonStyle(WireActionStyle(tint: isHandled ? Theme.textTertiary : Theme.ok))
            .help(isHandled ? "Mark as not handled" : "Mark as handled")
        }
    }

    private var divider: some View {
        Text("·")
            .font(Theme.mono(11))
            .foregroundStyle(Theme.textTertiary.opacity(0.5))
    }
}

// MARK: - Evidence (citations)

struct BriefCardEvidenceView: View {
    let card: BriefCard
    let briefID: Int64
    let repository: BriefRepository
    @State private var sources: [(source: BriefCardSource, message: Message?)] = []
    @State private var isLoading = true
    @State private var loadError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.45)
                    WireLabel("Pulling sources…")
                }
                .padding(.vertical, 2)
            } else if sources.isEmpty {
                if loadError != nil {
                    HStack(spacing: 10) {
                        Text("Could not load evidence.")
                            .font(Theme.sans(12))
                            .italic()
                            .foregroundStyle(Theme.textTertiary)
                        Button("RETRY") { Task { await loadEvidence() } }
                            .buttonStyle(WireActionStyle())
                    }
                } else {
                    Text("No direct evidence found in the local archive.")
                        .font(Theme.sans(12))
                        .italic()
                        .foregroundStyle(Theme.textTertiary)
                }
            } else {
                ForEach(sources, id: \.source.id) { item in
                    citation(item)
                }
            }
        }
        .padding(.leading, 14)
        .overlay(alignment: .leading) {
            Theme.border.frame(width: Theme.hairline)
        }
        .task { await loadEvidence() }
    }

    /// One source message, set like a print citation: mono attribution line,
    /// serif-italic quoted text.
    private func citation(_ item: (source: BriefCardSource, message: Message?)) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text((item.message?.sender ?? "Unknown").uppercased())
                    .font(Theme.mono(11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textSecondary)
                Text(item.message.map { timeStr($0.timestamp) } ?? "")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textTertiary)
                WireLabel(roleLabel(item.source.sourceRole),
                          color: item.source.sourceRole == "quote" ? Theme.standby : Theme.textTertiary)
                Spacer()
            }
            Text(item.message?.text ?? item.source.quoteText ?? "(No message text)")
                .font(Theme.display(13))
                .italic()
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func loadEvidence() async {
        isLoading = true
        loadError = nil
        do {
            sources = try repository.fetchSourcesWithMessages(briefID: briefID, service: card.service, conversationID: card.conversationId)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func roleLabel(_ role: String) -> String {
        switch role {
        case "quote": return "Quote"
        case "new_message": return "Supporting"
        case "recent_context": return "Context"
        default: return role.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func timeStr(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

// MARK: - Quick replies

private struct QuickReplyRow: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    let card: BriefCard

    var body: some View {
        let isLoading = chatViewModel.quickRepliesLoading.contains(card.id)
        let isFailed = chatViewModel.quickRepliesFailed.contains(card.id)
        let replies = chatViewModel.quickReplies[card.id] ?? []
        let convName = card.conversation ?? ""

        if isLoading {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.45)
                WireLabel("Drafting replies…")
            }
            .padding(.top, 2)
        } else if !replies.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    WireLabel("Send:")
                    ForEach(replies) { reply in
                        QuickReplyChip(reply: reply) {
                            chatViewModel.applyQuickReply(reply,
                                                          cardID: card.id,
                                                          service: card.service,
                                                          convId: card.conversationId,
                                                          convName: convName)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .padding(.top, 2)
        } else if card.priority == "high" || card.priority == "med" || !card.actions.isEmpty {
            Button(isFailed ? "RETRY QUICK REPLY" : "QUICK REPLY") {
                Task {
                    await chatViewModel.generateQuickReplies(
                        cardID: card.id,
                        service: card.service,
                        convId: card.conversationId,
                        convName: convName
                    )
                }
            }
            .buttonStyle(WireActionStyle(tint: Theme.textSecondary))
            .padding(.top, 1)
            .help("Generate one-tap reply drafts in your style")
        }
    }
}

// MARK: - Quick reply chip

private struct QuickReplyChip: View {
    let reply: QuickReply
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            Text(reply.label)
                .font(Theme.sans(12, weight: .medium))
                .foregroundStyle(isHovered ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isHovered ? Theme.surfaceHigh : Theme.surface)
                )
                .overlay(
                    Capsule().strokeBorder(isHovered ? Theme.textTertiary : Theme.border, lineWidth: Theme.hairline)
                )
        }
        .buttonStyle(.plain)
        .help(reply.draft)
        .animation(Theme.quick, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Label editor popover

struct LabelEditorPopover: View {
    let convName: String
    @Binding var label: String
    @Binding var priorityHint: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                WireLabel("Conversation context")
                Text(convName)
                    .font(Theme.display(14))
                    .foregroundStyle(Theme.textPrimary)
            }

            VStack(alignment: .leading, spacing: 6) {
                WireLabel("Label")
                TextField("e.g. manager, client, low-noise group", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.sans(13))
            }

            VStack(alignment: .leading, spacing: 6) {
                WireLabel("Priority hint")
                Picker("", selection: $priorityHint) {
                    Text("Auto").tag("auto")
                    Text("High").tag("high")
                    Text("Med").tag("med")
                    Text("Low").tag("low")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Text("Saved context is injected into every future brief for this conversation.")
                .font(Theme.sans(11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(WireActionStyle())
                Spacer()
                Button("Save", action: onSave)
                    .buttonStyle(PaperButtonStyle(prominent: true))
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
