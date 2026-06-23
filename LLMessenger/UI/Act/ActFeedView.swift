// LLMessenger/UI/Act/ActFeedView.swift
//
// Unified action feed — agent proposals + owed replies in one ranked list.
// Two semantic colours: red = someone is waiting on you, grey = self-directed.
// Keyboard-first: J/K to move, Return = approve, S = skip, E = edit.

import SwiftUI

// MARK: - Unified item type

enum ActItem: Identifiable {
    case agentAction(AgentAction)
    case owedReply(OwedReply)

    var id: String {
        switch self {
        case .agentAction(let a): return "action-\(a.id ?? 0)"
        case .owedReply(let r):   return "owed-\(r.id)"
        }
    }

    // Red = someone waits on you. Grey = self-directed.
    var isPersonWaiting: Bool {
        switch self {
        case .agentAction(let a):
            return a.kindEnum == .reply || a.kindEnum == .ack
        case .owedReply:
            return true
        }
    }

    var service: String {
        switch self {
        case .agentAction(let a): return a.service
        case .owedReply(let r):   return r.service
        }
    }

    var name: String {
        switch self {
        case .agentAction(let a): return a.conversationName
        case .owedReply(let r):   return r.conversationName
        }
    }

    var preview: String {
        switch self {
        case .agentAction(let a):
            return a.replyPayload?.draftText ?? a.title
        case .owedReply(let r):
            return r.triggerText
        }
    }

    var triggeredAt: Date {
        switch self {
        case .agentAction(let a): return a.createdAt
        case .owedReply(let r):   return r.triggeredAt
        }
    }

    var ageHours: Int {
        max(0, Int(Date().timeIntervalSince(triggeredAt) / 3600))
    }

    var isStale: Bool {
        switch self {
        case .agentAction: return ageHours > 48
        case .owedReply:   return ageHours > 72
        }
    }

    var typeIcon: String {
        switch self {
        case .agentAction(let a):
            switch a.kindEnum {
            case .reply:        return "arrow.turn.up.left"
            case .followUp:     return "clock.arrow.circlepath"
            case .calendarHold: return "calendar.badge.plus"
            case .rsvp:         return "calendar.badge.checkmark"
            case .ack:          return "hand.thumbsup"
            case .none:         return "ellipsis"
            }
        case .owedReply:
            return "arrow.turn.up.left"
        }
    }
}

// MARK: - Feed view

struct ActFeedView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel

    @State private var selectedIndex: Int? = nil

    private var items: [ActItem] {
        let actions = appState.agentActions
            .filter { !$0.isMaybe }
            .map { ActItem.agentAction($0) }
        let owed = appState.owedReplies
            .map { ActItem.owedReply($0) }
        // Agent actions first (have a suggested reply ready), then owed by priority
        return actions + owed
    }

    var body: some View {
        Group {
            if items.isEmpty {
                emptyState
            } else {
                feedContent
            }
        }
        // Keyboard navigation
        .background(
            Group {
                Button("") { moveSelection(by: 1) }
                    .keyboardShortcut("j", modifiers: [])
                Button("") { moveSelection(by: -1) }
                    .keyboardShortcut("k", modifiers: [])
                Button("") { approveSelected() }
                    .keyboardShortcut(.return, modifiers: [])
                Button("") { skipSelected() }
                    .keyboardShortcut("s", modifiers: [])
            }
            .opacity(0)
        )
    }

    // MARK: - Feed

    private var feedContent: some View {
        VStack(spacing: 0) {
            safetyNote
            Rule()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if appState.agentActions.contains(where: { $0.riskEnum == .low && !$0.isMaybe }) {
                        batchBar
                        Rule()
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        VStack(spacing: 0) {
                            ActCardRow(
                                item: item,
                                isSelected: selectedIndex == index,
                                onTap: { selectedIndex = index }
                            )
                            Rule()
                        }
                        .transition(.asymmetric(
                            insertion: .opacity,
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                    }
                }
                .animation(Theme.spring, value: items.map { $0.id })
                .padding(.bottom, 24)
            }
        }
    }

    private var safetyNote: some View {
        HStack {
            Image(systemName: "lock.shield")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            Text("Nothing sends until you approve it.")
                .font(Theme.sans(11))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 7)
        .background(Theme.surfaceHigh.opacity(0.35))
    }

    private var batchBar: some View {
        HStack {
            Spacer()
            Button("Approve all low-risk") { appState.batchApproveLowRisk() }
                .buttonStyle(WireActionStyle(tint: Theme.textSecondary))
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 8)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(Theme.sans(28, weight: .thin))
                .foregroundStyle(Theme.textTertiary.opacity(0.4))
                .padding(.bottom, 2)
            WireLabel("Act")
            Text("You're clear")
                .font(Theme.display(21))
                .foregroundStyle(Theme.textPrimary)
            Text("Nothing needs you right now.")
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
            if let latest = appState.briefs.sorted(by: { $0.createdAt > $1.createdAt }).first {
                Button("Read latest digest →") {
                    appState.selectedBriefID = latest.id
                }
                .buttonStyle(.plain)
                .font(Theme.sans(12))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .background(Theme.sidebar)
    }

    // MARK: - Keyboard helpers

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let next = (selectedIndex.map { $0 + delta } ?? 0)
        selectedIndex = max(0, min(items.count - 1, next))
    }

    private func approveSelected() {
        guard let idx = selectedIndex, idx < items.count else { return }
        switch items[idx] {
        case .agentAction(let a):
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
            appState.approveAction(a)
        case .owedReply:
            break // owed replies don't have a one-tap approve — opens detail
        }
    }

    private func skipSelected() {
        guard let idx = selectedIndex, idx < items.count else { return }
        switch items[idx] {
        case .agentAction(let a):
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            appState.skipAction(a)
        case .owedReply(let r):
            OwedReplyStore.dismiss(r.id)
            appState.reloadOwedReplies()
        }
    }
}

// MARK: - Card row

private struct ActCardRow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel

    let item: ActItem
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editText = ""

    private var accentColor: Color {
        item.isPersonWaiting ? Theme.signal : Theme.textTertiary
    }

    private var background: Color {
        if isSelected { return Theme.surface }
        if isHovered  { return Theme.surface.opacity(0.5) }
        return Color.clear
    }

    var body: some View {
        HStack(spacing: 0) {
            // 2-colour accent bar
            Rectangle()
                .fill(accentColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 5) {
                headerRow
                previewRow
                actionRow
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
        }
        .background(background)
        .animation(Theme.quick, value: isHovered)
        .animation(Theme.quick, value: isSelected)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 6) {
            ServiceStamp(service: item.service, size: 20)
            Text(item.name)
                .font(Theme.sans(13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if item.isStale {
                Text("going stale")
                    .font(Theme.mono(9.5, weight: .semibold))
                    .foregroundStyle(Theme.signal)
            } else {
                Text(relativeTime)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: Preview

    @ViewBuilder
    private var previewRow: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: item.typeIcon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(accentColor.opacity(0.65))
                .frame(width: 13)
                .padding(.top, 2)

            if isEditing, case .agentAction(let a) = item {
                TextEditor(text: $editText)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minHeight: 52)
                    .padding(5)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.controlRadius)
                            .fill(Theme.surfaceHigh)
                    )
            } else {
                Text(item.preview)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 6) {
            switch item {
            case .agentAction(let a):
                if a.statusEnum == .scheduled {
                    scheduledBar(a)
                } else if isEditing {
                    actionButton("SAVE", tint: Theme.standby) {
                        appState.editAction(a, newText: editText)
                        isEditing = false
                    }
                    actionButton("CANCEL") { isEditing = false }
                } else {
                    approveButton(a)
                    actionButton("EDIT") {
                        editText = a.replyPayload?.draftText ?? a.payload
                        isEditing = true
                    }
                    actionButton("SKIP") {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                        appState.skipAction(a)
                    }
                }
            case .owedReply(let r):
                if !isDraftingDisabled(r) {
                    replyButton(r)
                }
                actionButton("SNOOZE") {
                    OwedReplyStore.snooze(r.id, until: Date().addingTimeInterval(86400))
                    appState.reloadOwedReplies()
                }
                actionButton("DISMISS") {
                    OwedReplyStore.dismiss(r.id)
                    appState.reloadOwedReplies()
                }
            }
            Spacer()
        }
        .padding(.top, 2)
    }

    // MARK: - Button sub-components

    private func approveButton(_ action: AgentAction) -> some View {
        Button("APPROVE") {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
            appState.approveAction(action)
        }
        .buttonStyle(WireActionStyle(tint: Theme.standby))
        .accessibilityLabel("Approve and send suggested reply to \(action.conversationName)")
    }

    private func replyButton(_ reply: OwedReply) -> some View {
        Button("REPLY") {
            if appState.selectedBrief == nil, let id = appState.briefs.first?.id {
                appState.selectedBriefID = id
            }
            chatViewModel.prepareReply(
                service: reply.service,
                conversationID: reply.conversationId,
                displayName: reply.conversationName
            )
        }
        .buttonStyle(WireActionStyle(tint: Theme.standby))
    }

    private func scheduledBar(_ action: AgentAction) -> some View {
        ScheduledCountdownBar(action: action) {
            appState.undoAutoSend(action)
        }
    }

    private func actionButton(_ title: String, tint: Color = Theme.textTertiary, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(WireActionStyle(tint: tint))
    }

    // MARK: - Helpers

    private func isDraftingDisabled(_ reply: OwedReply) -> Bool {
        appState.fetchConversationContext(service: reply.service, conversationId: reply.conversationId)?
            .privacyOverride == "never_draft"
    }

    private var relativeTime: String {
        let hours = item.ageHours
        if hours < 1   { return "just now" }
        if hours < 24  { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }

    private var accessibilityLabel: String {
        switch item {
        case .agentAction(let a):
            return "Suggested reply for \(a.conversationName). \(a.replyPayload?.draftText ?? a.title)"
        case .owedReply(let r):
            return "Reply owed to \(r.conversationName). \(r.triggerText)"
        }
    }
}

// MARK: - Scheduled countdown (reused from ActionRow for delegation countdown)

private struct ScheduledCountdownBar: View {
    let action: AgentAction
    let onUndo: () -> Void

    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            Text("SENDING IN \(secondsRemaining)s")
                .font(Theme.mono(10.5, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Theme.signal)
            Button("UNDO", action: onUndo)
                .buttonStyle(WireActionStyle())
        }
        .onReceive(ticker) { now = $0 }
    }

    private var secondsRemaining: Int {
        guard let fireAt = action.scheduledAt else { return 0 }
        return max(0, Int(fireAt.timeIntervalSince(now).rounded(.up)))
    }
}
