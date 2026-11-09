// LLMessenger/UI/Act/ActFeedView.swift
//
// Single ranked work queue: Couldn't send / Needs your decision / Ready to send /
// Older / Waiting on others / Your promises and tasks. Each row answers who
// (name · full service), what (the draft), why now, and one primary action.
// Keyboard-first, but never blind: nothing is selected until the user presses
// J/K or clicks a row, ⌘Return acts on the selected row only (and asks first
// for a "maybe" or high-risk draft), and the selection clears after a send.
// ⌘-click multi-selects; batch sending appears only for 2+ compatible sends.

import Combine
import SwiftUI

// MARK: - Feed view

struct ActFeedView: View {
    @EnvironmentObject var appState: AppState
    let layout: DeskLayout

    /// Selection is by item id, never by position: rows move as the queue
    /// changes, and a send must only ever go to the row the user picked.
    @State private var selectedID: String? = nil
    /// Where the last resolved row was, so J/K pick up from there.
    @State private var anchorIndex: Int = 0
    @State private var resolvedInSession = 0
    /// ⌘-click multi-selection for batch approval of compatible sends.
    @State private var multiSelectedIds: Set<String> = []
    /// A "maybe"/high-risk draft the user pressed ⌘Return on — confirm first.
    @State private var confirmingAction: AgentAction? = nil

    init(layout: DeskLayout = .regular) {
        self.layout = layout
    }

    var items: [ActItem] {
        queueSections.flatMap(\.items)
    }

    /// Items keep their global attention rank inside each section; sections
    /// order by how urgently the user is needed. Honors the service filter.
    private var queueSections: [(section: ActQueueSection, items: [ActItem])] {
        let projected = appState.attentionProjection.actItems.filter {
            appState.serviceQuickFilter == nil || $0.service == appState.serviceQuickFilter
        }
        let now = Date()
        return ActQueueSection.allCases.compactMap { section in
            let rows = projected.filter { ActQueueRules.section(for: $0, now: now) == section }
            return rows.isEmpty ? nil : (section: section, items: rows)
        }
    }

    private var failedSends: [AgentAction] {
        appState.failedSends.filter {
            appState.serviceQuickFilter == nil || $0.service == appState.serviceQuickFilter
        }
    }

    private var filteredCommitments: [Commitment] {
        appState.attentionProjection.commitments.filter {
            appState.serviceQuickFilter == nil || $0.service == appState.serviceQuickFilter
        }
    }

    private var theyOweCommitments: [Commitment] {
        filteredCommitments.filter { $0.directionEnum != .iOwe }
    }

    private var iOweCommitments: [Commitment] {
        filteredCommitments.filter { $0.directionEnum == .iOwe }
    }

    /// Tasks have no `service` field of their own — resolve it through the
    /// card they came from so the promises section can honor the service
    /// filter the same way every other section does.
    private var filteredTasks: [BriefTask] {
        guard let filtered = appState.serviceQuickFilter else { return appState.attentionProjection.tasks }
        let serviceByCardID: [String: String] = Dictionary(
            appState.briefCardsByBriefID.values.flatMap { $0 }.map { ($0.id, $0.service) },
            uniquingKeysWith: { first, _ in first }
        )
        return appState.attentionProjection.tasks.filter { serviceByCardID[$0.briefCardId] == filtered }
    }

    private var isQueueEmpty: Bool {
        appState.attentionProjection.actItems.isEmpty
            && appState.attentionProjection.promiseCount == 0
            && appState.failedSends.isEmpty
    }

    private var selectedItem: ActItem? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    var body: some View {
        let items = self.items
        VStack(spacing: 0) {
            Group {
                if isQueueEmpty {
                    emptyState
                } else {
                    feedContent(items: items)
                }
            }
        }
        // Keyboard: J/K or ↓/↑ select, ⌘Return = the selected row's primary
        // button (never plain Return — a stray keystroke must not send a real
        // message), S = skip/dismiss, E = edit in the composer, ⌘Z = undo the
        // last staged send. Only while the main window is key with no sheet.
        .background {
            KeyboardShortcutMonitor(isEnabled: confirmingAction == nil) { event in
                if event.hasCommandOnly, event.normalizedKey == "z" {
                    return undoLastStaged()
                }
                if event.hasCommandOnly, event.keyCode == 36 {
                    performCommandReturn()
                    return true
                }
                guard event.hasNoCommandOptionControl else { return false }
                switch event.keyCode {
                case 125, 126: // down / up arrows — synonyms for J/K
                    moveSelection(by: event.keyCode == 125 ? 1 : -1)
                    return true
                case 53 where selectedID != nil: // Esc clears the selection
                    selectedID = nil
                    return true
                default:
                    break
                }
                switch event.normalizedKey {
                case "j":
                    moveSelection(by: 1)
                case "k":
                    moveSelection(by: -1)
                case "s":
                    skipSelected()
                case "e":
                    editSelected()
                default:
                    return false
                }
                return true
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .onChange(of: items.map(\.id)) { _, ids in
            // The selected row left the queue (sent, skipped, refreshed away):
            // clear the selection rather than letting it land on a neighbour.
            selectedID = ActQueueRules.retainedSelection(selectedID, in: ids)
        }
        .alert(confirmTitle, isPresented: Binding(
            get: { confirmingAction != nil },
            set: { if !$0 { confirmingAction = nil } }
        ), presenting: confirmingAction) { action in
            Button("Send") { stage(action) }
            Button("Cancel", role: .cancel) { confirmingAction = nil }
        } message: { action in
            Text(confirmMessage(for: action))
        }
    }

    // MARK: - Feed

    private func feedContent(items: [ActItem]) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let sections = queueSections
                        // Always visible while filtered — not just when it empties
                        // the queue. Filtering out items with zero on-screen
                        // indication reads as "items are missing", not "I'm
                        // filtered"; that's a state an Apple review would block.
                        if let filtered = appState.serviceQuickFilter {
                            let isEmpty = sections.isEmpty && failedSends.isEmpty
                                && theyOweCommitments.isEmpty && iOweCommitments.isEmpty
                            HStack(spacing: 8) {
                                Text(isEmpty
                                     ? "Nothing from \(Theme.serviceName(filtered)) needs you."
                                     : "\(Theme.serviceName(filtered).uppercased()) ONLY")
                                    .font(isEmpty ? Theme.sans(12.5) : Theme.wireSection)
                                    .tracking(isEmpty ? 0 : Theme.wireSectionTracking)
                                    .foregroundStyle(Theme.textSecondary)
                                Spacer(minLength: 8)
                                Button("SHOW ALL") {
                                    withAnimation(Theme.quick) { appState.serviceQuickFilter = nil }
                                }
                                .buttonStyle(WireActionStyle())
                            }
                            .padding(.horizontal, layout.gutter)
                            .padding(.vertical, isEmpty ? 16 : 9)
                            .background(isEmpty ? Color.clear : Theme.surfaceHigh.opacity(0.4))
                        }

                        if ActQueueRules.isCaughtUp(items: items, failedSends: failedSends) {
                            caughtUpHeader(olderCount: items.count)
                        }

                        if !failedSends.isEmpty {
                            VStack(spacing: 0) {
                                sectionHeader("Couldn't send",
                                              caption: "Not delivered — try again, edit or dismiss",
                                              color: Theme.signal)
                                ForEach(failedSends) { action in
                                    FailedSendRow(action: action, layout: layout)
                                    Rule()
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("Couldn't send")
                        }

                        ForEach(sections, id: \.section) { entry in
                            VStack(spacing: 0) {
                                // Vermilion only where someone needs a decision.
                                sectionHeader(entry.section.title,
                                              caption: entry.section.caption,
                                              color: entry.section == .decision ? Theme.signal
                                                  : (entry.section == .ready ? Theme.textSecondary : Theme.textTertiary))
                                ForEach(entry.items, id: \.id) { item in
                                    actRow(item: item)
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(entry.section.title)
                        }

                        if !theyOweCommitments.isEmpty {
                            VStack(spacing: 0) {
                                sectionHeader("Waiting on others",
                                              caption: "Things people told you they'd do",
                                              color: Theme.textTertiary)
                                ForEach(theyOweCommitments) { c in
                                    commitmentRow(c)
                                    Rule()
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("Waiting on others")
                        }

                        if !iOweCommitments.isEmpty || !filteredTasks.isEmpty {
                            VStack(spacing: 0) {
                                sectionHeader("Your promises and tasks",
                                              caption: "Things you said you'd do",
                                              color: Theme.textTertiary)
                                ForEach(iOweCommitments) { c in
                                    commitmentRow(c)
                                    Rule()
                                }
                                ForEach(filteredTasks, id: \.id) { t in
                                    taskRow(t)
                                    Rule()
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("Your promises and tasks")
                        }
                    }
                    .animation(Theme.spring, value: items.map { $0.id })
                    .padding(.bottom, 24)
                }
                .onChange(of: selectedID) { _, newID in
                    guard let newID else { return }
                    withAnimation(Theme.quick) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }

            // Batch sending surfaces only once 2+ compatible sends are ⌘-selected —
            // it is not a permanent strip over the queue. The safety window is stated
            // here, where it's relevant to the send.
            if batchSelectedActions.count >= 2 {
                Rule()
                batchSelectionBar
            }
        }
    }

    private func caughtUpHeader(olderCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            WireLabel("Nothing waiting on you", color: Theme.ok)
            Text("You're all caught up")
                .font(Theme.display(19))
                .foregroundStyle(Theme.textPrimary)
            Text(olderCount > 0
                 ? "Nothing new needs a decision or is ready to send. Older items and promises are below."
                 : "Nothing needs a decision or is ready to send. What you're waiting on is below.")
                .font(Theme.sans(12))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, layout.gutter)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
    }

    private func actRow(item: ActItem) -> some View {
        VStack(spacing: 0) {
            Button {
                if NSEvent.modifierFlags.contains(.command) {
                    toggleMultiSelect(item)
                } else {
                    multiSelectedIds.removeAll()
                    selectedID = (selectedID == item.id) ? nil : item.id
                }
            } label: {
                ActCardRow(
                    item: item,
                    layout: layout,
                    isSelected: selectedID == item.id,
                    onSend: { stage($0) },
                    onResolved: { resolved(item) }
                )
                .id(item.id)
            }
            .buttonStyle(.plain)
            .background(multiSelectedIds.contains(item.id) ? Theme.standby.opacity(0.08) : Color.clear)
            .accessibilityLabel(item.accessibilitySummary)
            Rule()
        }
        .transition(.asymmetric(
            insertion: .opacity,
            removal: .move(edge: .trailing).combined(with: .opacity)
        ))
    }

    private func sectionHeader(_ title: String, caption: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            WireLabel(title, color: color)
                .fixedSize()
            Text(caption)
                .font(Theme.sans(11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, layout.gutter)
        .padding(.vertical, 9)
        .background(Theme.surfaceHigh.opacity(0.5))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(title). \(caption)")
    }

    // MARK: - Multi-select batch approval

    /// ⌘-selected actions that can be batch-sent: pending drafted sends, not
    /// "maybe", not high-risk, not external, not user-written. Anything else is
    /// incompatible and keeps the batch bar hidden.
    private var batchSelectedActions: [AgentAction] {
        items.compactMap { item -> AgentAction? in
            guard multiSelectedIds.contains(item.id),
                  case .agentAction(let action) = item,
                  action.isBatchEligible
            else { return nil }
            return action
        }
    }

    private var batchSelectionBar: some View {
        let actions = batchSelectedActions
        return HStack {
            Text("\(actions.count) sends selected · each waits 5s and can be undone")
                .font(Theme.sans(11.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
            Spacer()
            Button("SEND \(actions.count)") {
                for action in actions {
                    appState.stageSend(action)
                }
                resolvedInSession += actions.count
                multiSelectedIds.removeAll()
                selectedID = nil
            }
            .buttonStyle(PaperButtonStyle(prominent: true, labelFont: Theme.mono(11, weight: .bold), tracking: 0.4))
            .accessibilityLabel("Send \(actions.count) selected replies")
            .accessibilityHint("Each send waits 5 seconds and can be undone before it sends.")
            Button("CANCEL") { multiSelectedIds.removeAll() }
                .buttonStyle(WireActionStyle())
        }
        .padding(.horizontal, layout.gutter)
        .padding(.vertical, 10)
        .background(Theme.surfaceHigh.opacity(0.5))
    }

    private func toggleMultiSelect(_ item: ActItem) {
        if multiSelectedIds.contains(item.id) {
            multiSelectedIds.remove(item.id)
        } else {
            multiSelectedIds.insert(item.id)
        }
    }

    // MARK: - Commitment / task rows (the former to-do strip, folded into the queue)

    private func commitmentRow(_ c: Commitment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(c.directionEnum == .iOwe ? "YOU" : "THEM")
                .font(Theme.mono(10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: layout == .compact ? 42 : 36, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.what)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(layout == .compact ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(c.conversationName) · \(Theme.serviceName(c.service))")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer()
            Button { appState.markCommitmentFulfilled(c) } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .help(c.directionEnum == .iOwe ? "Mark done" : "Mark received")
                .accessibilityLabel(c.directionEnum == .iOwe
                    ? "Mark done, you delivered: \(c.what)"
                    : "Mark received, they delivered: \(c.what)")
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.horizontal, layout.gutter)
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(c.directionEnum == .iOwe ? "You owe" : "They owe"): \(c.what), \(c.conversationName)")
    }

    private func taskRow(_ t: BriefTask) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("—")
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textTertiary)
            Text(t.text)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(layout == .compact ? 2 : nil)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Spacer()
            Button { if let id = t.id { appState.completeTask(id) } } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .help("Mark done")
                .accessibilityLabel("Complete task: \(t.text)")
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.horizontal, layout.gutter)
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Task: \(t.text)")
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: appState.briefs.isEmpty ? "ellipsis.circle" : "checkmark.circle")
                .font(Theme.sans(28, weight: .thin))
                .foregroundStyle(Theme.textTertiary.opacity(0.4))
                .padding(.bottom, 2)
            Text(appState.briefs.isEmpty ? "No actions yet" : "You're all caught up")
                .font(Theme.display(21))
                .foregroundStyle(Theme.textPrimary)
            Group {
                if resolvedInSession > 0 {
                    Text(sessionClearDetail)
                } else {
                    Text(emptyDetail)
                }
            }
            .font(Theme.sans(12.5))
            .foregroundStyle(Theme.textPrimary)
            .multilineTextAlignment(.center)
            if let latest = appState.briefs.max(by: { $0.createdAt < $1.createdAt }) {
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

    private var emptyDetail: String {
        if appState.briefs.isEmpty {
            return "Actions will appear here after your first digest."
        }
        if let next = appState.nextPollDate {
            return "Nothing needs you right now. Leave it here; next check \(next.actRelativeLabel)."
        }
        return "Nothing needs you right now. We'll interrupt only for likely important items."
    }

    private var sessionClearDetail: String {
        var parts = ["\(resolvedInSession) handled this session", "no tracked reply is waiting"]
        let metrics = appState.productLoveMetrics
        if metrics.handledCards > resolvedInSession {
            parts.append("\(metrics.handledCards) handled all-time")
        }
        if let next = appState.nextPollDate {
            parts.append("next check \(next.actRelativeLabel)")
        }
        return parts.joined(separator: " · ") + "."
    }

    // MARK: - Sending and confirmation

    private func stage(_ action: AgentAction) {
        confirmingAction = nil
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        appState.stageSend(action)
        resolvedInSession += 1
        // Never leave a send's selection on whatever row slides into its place.
        if let index = items.firstIndex(where: { $0.id == ActItem.agentAction(action).id }) {
            anchorIndex = index
        }
        selectedID = nil
    }

    private func resolved(_ item: ActItem) {
        resolvedInSession += 1
        if let index = items.firstIndex(where: { $0.id == item.id }) { anchorIndex = index }
        if selectedID == item.id { selectedID = nil }
    }

    private var confirmTitle: String {
        guard let action = confirmingAction else { return "Send?" }
        return "Send to \(action.conversationName) on \(Theme.serviceName(action.service))?"
    }

    private func confirmMessage(for action: AgentAction) -> String {
        let why = action.isMaybe
            ? "This draft is marked Maybe — the message might not need a reply."
            : "This draft needs a closer look: it mentions money or a link, or goes to someone you haven't written to before."
        let text = action.replyPayload?.draftText ?? action.calendarPayload?.replyText ?? action.title
        return "\(why)\n\n“\(text)”\n\nYou'll have 5 seconds to undo."
    }

    // MARK: - Keyboard helpers

    private func moveSelection(by delta: Int) {
        selectedID = ActQueueRules.moveSelection(from: selectedID, anchor: anchorIndex, by: delta, in: items)
    }

    private func performCommandReturn() {
        switch ActQueueRules.commandReturn(for: selectedItem) {
        case .none, .alreadySending:
            NSSound.beep()
        case .stage(let action):
            stage(action)
        case .confirm(let action):
            confirmingAction = action
        case .compose(let item):
            compose(item)
        }
    }

    private func compose(_ item: ActItem) {
        switch item {
        case .owedReply(let reply):
            appState.openReplyComposer(service: reply.service,
                                       conversationId: reply.conversationId,
                                       conversationName: reply.conversationName)
        case .agentAction(let action):
            appState.openComposer(editing: action)
        }
    }

    private func skipSelected() {
        guard let item = selectedItem else { return }
        switch item {
        case .agentAction(let a):
            guard a.statusEnum != .scheduled else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            appState.skipAction(a)
        case .owedReply(let r):
            OwedReplyStore.dismiss(r.id)
            appState.reloadOwedReplies()
            appState.showReceipt("Dismissed owed reply.", actionTitle: "Undo") {
                OwedReplyStore.undismiss(r.id)
                appState.reloadOwedReplies()
                appState.recordUndo()
            }
        }
        resolved(item)
    }

    /// E — edit the selected draft in the Reply composer.
    private func editSelected() {
        guard case .agentAction(let action) = selectedItem,
              action.statusEnum == .pending,
              ActCardRow.isEditable(action) else { return }
        appState.openComposer(editing: action)
    }

    @discardableResult
    private func undoLastStaged() -> Bool {
        guard let staged = AgentAction.mostRecentlyStaged(in: appState.agentActions) else { return false }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        appState.undoStagedSend(staged)
        resolvedInSession = max(0, resolvedInSession - 1)
        return true
    }
}

// MARK: - Card row

private struct ActCardRow: View {
    @EnvironmentObject var appState: AppState

    let item: ActItem
    let layout: DeskLayout
    let isSelected: Bool
    let onSend: (AgentAction) -> Void
    var onResolved: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var showContextEditor = false

    /// Only message drafts are edited in the composer; calendar and RSVP
    /// actions carry structured payloads, not free text.
    static func isEditable(_ action: AgentAction) -> Bool {
        switch action.kindEnum {
        case .reply, .followUp, .ack: return true
        case .rsvp, .calendarHold, .none: return false
        }
    }

    /// Vermilion is reserved for items still awaiting a decision — matching the
    /// "Needs your decision" section, not every person-waiting item. A drafted
    /// reply that's merely Ready to send is not an emergency.
    private var needsDecision: Bool {
        switch item {
        case .agentAction(let action):
            return ActQueueRules.needsDecision(action)
        case .owedReply:
            return true
        }
    }

    private var accentColor: Color {
        needsDecision ? Theme.signal : Theme.textTertiary
    }

    private var background: Color {
        if isSelected { return Theme.surface }
        if isHovered  { return Theme.surface.opacity(0.5) }
        return Color.clear
    }

    var body: some View {
        HStack(spacing: 0) {
            // 2-colour accent bar: wider + brighter when selected
            Rectangle()
                .fill(accentColor)
                .frame(width: isSelected ? 4 : 3)
                .animation(Theme.quick, value: isSelected)

            VStack(alignment: .leading, spacing: 5) {
                headerRow
                originLine
                previewRow
                // Expanded detail: shown when card is selected
                if isSelected {
                    detailRow
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                actionRow
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .animation(Theme.spring, value: isSelected)
            // Cap the reading measure — past ~760pt a row becomes a sparse ribbon
            // the eye must travel end-to-end to associate with its checkmark.
            // The accent bar and hover/selection fill (outside this VStack) stay
            // full-width so click/hover targets are unaffected.
            .frame(maxWidth: 760, alignment: .leading)
        }
        .background(background)
        // Focus ring on selected card
        .overlay(
            isSelected
                ? RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(accentColor.opacity(0.35), lineWidth: 1)
                : nil
        )
        .animation(Theme.quick, value: isHovered)
        .animation(Theme.quick, value: isSelected)
        .onHover { isHovered = $0 }
        .sheet(isPresented: $showContextEditor) {
            contextEditorSheet
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAction(named: primaryAccessibilityActionName) {
            performPrimaryAccessibilityAction()
        }
    }

    @ViewBuilder
    private var contextEditorSheet: some View {
        ContextEditor(
            service: item.service,
            conversationId: item.conversationId,
            conversationName: item.name,
            database: appState.database
        )
    }

    // MARK: Header — who and where

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ServiceStamp(service: item.service, size: 20)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            // Serif anchor — without it Act was the one screen with no editorial
            // identity, reading as a terminal next to Digests' newspaper.
            Text(item.name)
                .font(Theme.display(14.5))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
            Text("· \(Theme.serviceName(item.service))")
                .font(Theme.sans(12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 4)
            if case .agentAction(let action) = item, action.isMaybe {
                WireLabel("Maybe", color: Theme.standby)
            }
            if case .agentAction(let action) = item, action.isExternalProposal {
                WireLabel("External agent", color: Theme.signal)
                    .accessibilityLabel("Proposed by an external agent")
            }
            if item.isStale {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                    Text("\(item.ageHours / 24)d waiting")
                        .font(Theme.mono(10, weight: .semibold))
                }
                .foregroundStyle(Theme.standby)
            } else {
                Text(relativeTime)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    /// One plain line when the text didn't come from LLMessenger's own drafting.
    @ViewBuilder
    private var originLine: some View {
        if case .agentAction(let action) = item {
            if action.isExternalProposal {
                Text("Drafted by an AI app you connected. Review it before it goes out.")
                    .font(Theme.sans(11.5))
                    .foregroundStyle(Theme.textSecondary)
            } else if action.isUserComposed {
                Text("Written by you")
                    .font(Theme.sans(11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: Preview — the whole draft when selected

    private var previewRow: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: item.typeIcon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(accentColor.opacity(0.65))
                .frame(width: 13)
                .padding(.top, 2)
            Text(item.preview)
                .font(Theme.bodyFont)
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(isSelected ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    // MARK: Detail (expanded when selected)

    @ViewBuilder
    private var detailRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Reasoning context — why the agent surfaced this
            switch item {
            case .agentAction(let a) where !a.reasoning.isEmpty && !a.isUserComposed && !a.isExternalProposal:
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 13)
                        .padding(.top, 2)
                    Text(a.reasoning)
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .owedReply(let r):
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 13)
                        .padding(.top, 2)
                    Text(r.reason)
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            default:
                EmptyView()
            }

            Button("Conversation settings") { showContextEditor = true }
                .buttonStyle(WireActionStyle(sansLabel: true))
                .accessibilityLabel("Edit priority and delegation settings for \(item.name)")
        }
        .padding(.vertical, 2)
    }

    // MARK: Actions

    @ViewBuilder
    private var actionRow: some View {
        if layout == .compact {
            VStack(alignment: .leading, spacing: 6) {
                actionControls
            }
            .padding(.top, 2)
        } else {
            HStack(spacing: 6) {
                actionControls
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var actionControls: some View {
        switch item {
        case .agentAction(let a):
            if a.statusEnum == .scheduled {
                scheduledBar(a)
            } else if layout == .compact {
                VStack(alignment: .leading, spacing: 6) {
                    primaryButton(a)
                    HStack(spacing: 6) {
                        if Self.isEditable(a) && ActQueueRules.sendsFromRow(a) { editButton(a) }
                        skipButton(a)
                    }
                }
            } else {
                primaryButton(a)
                if Self.isEditable(a) && ActQueueRules.sendsFromRow(a) { editButton(a) }
                skipButton(a)
            }
        case .owedReply(let r):
            if layout == .compact {
                VStack(alignment: .leading, spacing: 6) {
                    replyButton(r)
                    HStack(spacing: 6) {
                        snoozeButton(r)
                        dismissButton(r)
                    }
                }
            } else {
                replyButton(r)
                snoozeButton(r)
                dismissButton(r)
            }
        }
    }

    // MARK: - Button sub-components

    private func keyHint(_ key: String) -> some View {
        Text(key)
            .font(Theme.mono(10, weight: .semibold))
            .opacity(0.6)
    }

    @ViewBuilder
    private func primaryButton(_ action: AgentAction) -> some View {
        if ActQueueRules.sendsFromRow(action) {
            sendButton(action)
        } else {
            // External proposals never send from the row: a different, outlined
            // control that opens the composer, so muscle memory can't approve it.
            Button {
                appState.openComposer(editing: action)
            } label: {
                HStack(spacing: 6) {
                    Text("REVIEW…")
                    if isSelected { keyHint("⌘↩") }
                }
            }
            .buttonStyle(PaperButtonStyle(labelFont: Theme.mono(11, weight: .bold), tracking: 0.4))
            .help("Open this draft in the Reply window before sending")
            .accessibilityLabel("Review the external agent's draft to \(action.conversationName)")
        }
    }

    private func sendButton(_ action: AgentAction) -> some View {
        HStack(spacing: 7) {
            Button {
                onSend(action)
            } label: {
                HStack(spacing: 6) {
                    Text("SEND")
                    if isSelected { keyHint("⌘↩") }
                }
            }
            .buttonStyle(PaperButtonStyle(prominent: true, labelFont: Theme.mono(11, weight: .bold), tracking: 0.4))
            .help("Send to \(action.conversationName) on \(Theme.serviceName(action.service)) — you'll have 5 seconds to undo")
            .accessibilityLabel("Send to \(action.conversationName) on \(Theme.serviceName(action.service))")
            .accessibilityHint("Sends in 5 seconds unless undone. Keyboard: select the row, then Command Return.")
            Text("5s to undo")
                .font(Theme.sans(11))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
    }

    private func replyButton(_ reply: OwedReply) -> some View {
        let canSend = ServiceCapabilities.canSend(service: reply.service)
        return Button {
            appState.openReplyComposer(service: reply.service,
                                       conversationId: reply.conversationId,
                                       conversationName: reply.conversationName)
        } label: {
            HStack(spacing: 6) {
                Text(canSend ? "REPLY…" : "REPLY IN \(Theme.serviceName(reply.service).uppercased())…")
                if isSelected { keyHint("⌘↩") }
            }
        }
        .buttonStyle(PaperButtonStyle(prominent: canSend, labelFont: Theme.mono(11, weight: .bold), tracking: 0.4))
        .help(canSend
              ? "Write a reply to \(reply.conversationName)"
              : "LLMessenger can read \(Theme.serviceName(reply.service)) but can't send through it — copy your reply and open \(Theme.serviceName(reply.service))")
        .accessibilityLabel(canSend
              ? "Reply to \(reply.conversationName) on \(Theme.serviceName(reply.service))"
              : "Reply in \(Theme.serviceName(reply.service)). LLMessenger can't send \(Theme.serviceName(reply.service)) messages.")
    }

    private func scheduledBar(_ action: AgentAction) -> some View {
        ScheduledCountdownBar(action: action) {
            appState.undoStagedSend(action)
        }
    }

    private func editButton(_ action: AgentAction) -> some View {
        actionButton("Edit", key: "E") {
            appState.openComposer(editing: action)
        }
        .accessibilityLabel("Edit the draft to \(action.conversationName)")
    }

    private func skipButton(_ action: AgentAction) -> some View {
        actionButton("Skip", key: "S") {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            appState.skipAction(action)
            onResolved?()
        }
    }

    private func snoozeButton(_ reply: OwedReply) -> some View {
        actionButton("Snooze") {
            OwedReplyStore.snooze(reply.id, until: Date().addingTimeInterval(86400))
            appState.reloadOwedReplies()
            appState.showReceipt("Snoozed reply until tomorrow.", actionTitle: "Undo") {
                OwedReplyStore.unsnooze(reply.id)
                appState.reloadOwedReplies()
                appState.recordUndo()
            }
            onResolved?()
        }
    }

    private func dismissButton(_ reply: OwedReply) -> some View {
        actionButton("Dismiss", key: "S") {
            OwedReplyStore.dismiss(reply.id)
            appState.reloadOwedReplies()
            appState.showReceipt("Dismissed owed reply.", actionTitle: "Undo") {
                OwedReplyStore.undismiss(reply.id)
                appState.reloadOwedReplies()
                appState.recordUndo()
            }
            onResolved?()
        }
    }

    private func actionButton(_ title: String, key: String? = nil, tint: Color = Theme.textTertiary,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if isSelected, let key { keyHint(key) }
            }
        }
        .buttonStyle(WireActionStyle(tint: tint, sansLabel: true))
    }

    // MARK: - Helpers

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
            return "Draft reply to \(a.conversationName) on \(Theme.serviceName(a.service)). \(a.replyPayload?.draftText ?? a.title)"
        case .owedReply(let r):
            return "Reply owed to \(r.conversationName) on \(Theme.serviceName(r.service)). \(r.triggerText)"
        }
    }

    private var primaryAccessibilityActionName: String {
        switch item {
        case .agentAction(let a):
            if a.statusEnum == .scheduled { return "Undo scheduled send" }
            return ActQueueRules.sendsFromRow(a) ? "Send" : "Review"
        case .owedReply:
            return "Reply"
        }
    }

    private func performPrimaryAccessibilityAction() {
        switch item {
        case .agentAction(let a):
            if a.statusEnum == .scheduled {
                appState.undoStagedSend(a)
            } else if ActQueueRules.sendsFromRow(a) {
                onSend(a)
            } else {
                appState.openComposer(editing: a)
            }
        case .owedReply(let r):
            appState.openReplyComposer(service: r.service,
                                       conversationId: r.conversationId,
                                       conversationName: r.conversationName)
        }
    }
}

// MARK: - Couldn't send

/// A send that failed stays in Act with everything needed to decide again:
/// who, where, the exact text, why it failed, and what to do.
private struct FailedSendRow: View {
    @EnvironmentObject var appState: AppState
    let action: AgentAction
    let layout: DeskLayout

    private var text: String {
        action.replyPayload?.draftText ?? action.calendarPayload?.replyText ?? action.title
    }

    private var failedAgo: String {
        let minutes = Int(Date().timeIntervalSince(action.resolvedAt ?? action.createdAt) / 60)
        if minutes < 1 { return "failed just now" }
        if minutes < 60 { return "failed \(minutes)m ago" }
        if minutes < 1440 { return "failed \(minutes / 60)h ago" }
        return "failed \(minutes / 1440)d ago"
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Theme.signal)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    ServiceStamp(service: action.service, size: 20)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Text(action.conversationName)
                        .font(Theme.display(14.5))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text("· \(Theme.serviceName(action.service))")
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize()
                    Spacer(minLength: 4)
                    Text(failedAgo)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(text)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.signal)
                        .padding(.top, 2)
                    Text(appState.failureReason(for: action))
                        .font(Theme.sans(11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Button("TRY AGAIN") { appState.retryFailedSend(action) }
                        .buttonStyle(PaperButtonStyle(prominent: true, labelFont: Theme.mono(11, weight: .bold), tracking: 0.4))
                        .help("Send it again — you'll have 5 seconds to undo")
                        .accessibilityLabel("Try sending to \(action.conversationName) on \(Theme.serviceName(action.service)) again")
                    if ActCardRow.isEditable(action) {
                        Button("Edit") { appState.openComposer(editing: action) }
                            .buttonStyle(WireActionStyle(tint: Theme.textTertiary, sansLabel: true))
                    }
                    Button("Dismiss") { appState.dismissFailedSend(action) }
                        .buttonStyle(WireActionStyle(tint: Theme.textTertiary, sansLabel: true))
                        .help("Remove it from Act without sending")
                    Spacer()
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Couldn't send to \(action.conversationName) on \(Theme.serviceName(action.service)). \(text)")
    }
}

// MARK: - Scheduled countdown with visual progress bar

private struct ScheduledCountdownBar: View {
    let action: AgentAction
    let onUndo: () -> Void

    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("SENDING IN \(secondsRemaining)s")
                    .font(Theme.mono(10.5, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(Theme.signal)
                    .monospacedDigit()
                Button("UNDO", action: onUndo)
                    .buttonStyle(WireActionStyle())
                    .accessibilityLabel("Undo — cancel this send to \(action.conversationName)")
            }
            // Draining progress bar: full → empty as time ticks down
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.surfaceHigh)
                        .frame(height: 2)
                    Rectangle()
                        .fill(Theme.standby.opacity(0.8))
                        .frame(width: geo.size.width * CGFloat(progress), height: 2)
                        .animation(.linear(duration: 1), value: progress)
                }
            }
            .frame(height: 2)
            .accessibilityHidden(true)
        }
        .onReceive(ticker) { now = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scheduled send")
        .accessibilityValue("\(secondsRemaining) seconds remaining")
    }

    private var secondsRemaining: Int {
        guard let fireAt = action.scheduledAt else { return 0 }
        return max(0, Int(fireAt.timeIntervalSince(now).rounded(.up)))
    }

    // 1.0 when just staged, drains toward 0
    private var progress: Double {
        guard let fireAt = action.scheduledAt else { return 0 }
        let remaining = fireAt.timeIntervalSince(now)
        return max(0, min(1, remaining / action.scheduledUndoWindow))
    }
}

private extension Date {
    var actRelativeLabel: String {
        let seconds = Date().timeIntervalSince(self)
        let absSeconds = abs(seconds)
        if absSeconds < 60 { return seconds < 0 ? "soon" : "just now" }
        if absSeconds < 3600 {
            let minutes = Int(absSeconds / 60)
            return seconds < 0 ? "in \(minutes)m" : "\(minutes)m ago"
        }
        if absSeconds < 86400 {
            let hours = Int(absSeconds / 3600)
            return seconds < 0 ? "in \(hours)h" : "\(hours)h ago"
        }
        let days = Int(absSeconds / 86400)
        return seconds < 0 ? "in \(days)d" : "\(days)d ago"
    }
}
