// LLMessenger/UI/Act/ActFeedView.swift
//
// Single ranked work queue: Needs your decision / Ready to send / Waiting on
// others / Later. Each row answers who, what, why now, and one primary action.
// Two semantic colours: red = someone is waiting on you, grey = self-directed.
// Keyboard-first: J/K to move, Return = approve, S = skip, E = edit.
// ⌘-click multi-selects; batch approval appears only for 2+ compatible sends.

import Combine
import SwiftUI

// MARK: - Feed view

struct ActFeedView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel
    let layout: DeskLayout

    @State private var selectedIndex: Int? = nil
    @State private var resolvedInSession = 0
    @State private var editingItemId: String? = nil
    /// ⌘-click multi-selection for batch approval of compatible sends.
    @State private var multiSelectedIds: Set<String> = []

    init(layout: DeskLayout = .regular) {
        self.layout = layout
    }

    // Rebuild + sort once per data change, not once per body evaluation — `body`,
    // feedContent's ForEach/animation, and onChange all read this same array,
    // which previously meant ~4 sorts per render pass.
    var items: [ActItem] {
        queueSections.flatMap(\.items)
    }

    /// The four-section queue. Items keep their global attention rank inside
    /// each section; sections order by how urgently the user is needed.
    /// Honors the sidebar service quick-filter.
    private var queueSections: [(title: String, items: [ActItem])] {
        var decision: [ActItem] = []
        var ready: [ActItem] = []
        var later: [ActItem] = []
        let projected = appState.attentionProjection.actItems.filter {
            appState.serviceQuickFilter == nil || $0.service == appState.serviceQuickFilter
        }
        for item in projected {
            if item.isStale {
                later.append(item)
                continue
            }
            switch item {
            case .agentAction(let action):
                if action.isMaybe || action.riskEnum == .high {
                    decision.append(item)
                } else {
                    ready.append(item)
                }
            case .owedReply:
                // No draft exists yet — the user decides what (or whether) to say.
                decision.append(item)
            }
        }
        return [
            ("Needs your decision", decision),
            ("Ready to send", ready),
            ("Later", later),
        ].filter { !$0.1.isEmpty }.map { (title: $0.0, items: $0.1) }
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
    /// card they came from so the "Later" section can honor the service
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
        .onAppear {
            // Auto-select first item so keyboard nav is immediately active
            if selectedIndex == nil && !items.isEmpty {
                selectedIndex = 0
            }
        }
        // Keyboard navigation — J/K or ↑/↓ move, ⌘Return = queue send (never plain
        // Return — a stray keystroke must not send a real message), S = skip,
        // E = edit, ⌘Z = undo staged.
        .background {
            KeyboardShortcutMonitor(isEnabled: editingItemId == nil) { event in
                if event.hasCommandOnly, event.normalizedKey == "z" {
                    undoLastStaged()
                    return true
                }
                if event.hasCommandOnly, event.keyCode == 36 {
                    approveSelected()
                    return true
                }
                guard event.hasNoCommandOptionControl else { return false }
                switch event.keyCode {
                case 125, 126: // down / up arrows — synonyms for J/K
                    moveSelection(by: event.keyCode == 125 ? 1 : -1)
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
        .onChange(of: items.count) { _, newCount in
            // Clamp selection when items shrink; preserve as much as possible
            if let idx = selectedIndex, idx >= newCount {
                selectedIndex = newCount > 0 ? newCount - 1 : nil
            }
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
                            let isEmpty = sections.isEmpty && theyOweCommitments.isEmpty && iOweCommitments.isEmpty
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
                        ForEach(sections, id: \.title) { section in
                            VStack(spacing: 0) {
                                sectionHeader(section.title,
                                              color: section.title == "Later" ? Theme.textTertiary : Theme.signal)
                                ForEach(section.items, id: \.id) { item in
                                    let index = items.firstIndex { $0.id == item.id } ?? 0
                                    actRow(item: item, index: index)
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(section.title)
                        }

                        if !theyOweCommitments.isEmpty {
                            VStack(spacing: 0) {
                                sectionHeader("Waiting on others", color: Theme.textTertiary)
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
                                sectionHeader("Later · promises and tasks", color: Theme.textTertiary)
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
                            .accessibilityLabel("Later, promises and tasks")
                        }
                    }
                    .animation(Theme.spring, value: items.map { $0.id })
                    .padding(.bottom, 24)
                }
                .onChange(of: selectedIndex) { _, newIdx in
                    guard let idx = newIdx, idx < items.count else { return }
                    withAnimation(Theme.quick) {
                        proxy.scrollTo(items[idx].id, anchor: .center)
                    }
                }
            }

            // Batch approval surfaces only once 2+ compatible sends are ⌘-selected —
            // it is not a permanent strip over the queue. The safety window is stated
            // here, where it's relevant to the send.
            if batchSelectedActions.count >= 2 {
                Rule()
                batchSelectionBar
            }
        }
    }

    private func actRow(item: ActItem, index: Int) -> some View {
        let isEditingThisCard = Binding<Bool>(
            get: { editingItemId == item.id },
            set: { if $0 { editingItemId = item.id } else if editingItemId == item.id { editingItemId = nil } }
        )
        return VStack(spacing: 0) {
            Button {
                if NSEvent.modifierFlags.contains(.command) {
                    toggleMultiSelect(item)
                } else {
                    multiSelectedIds.removeAll()
                    selectedIndex = index
                }
            } label: {
                ActCardRow(
                    item: item,
                    layout: layout,
                    isSelected: selectedIndex == index,
                    isEditingExternal: isEditingThisCard,
                    onResolved: { resolvedInSession += 1 }
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

    private func sectionHeader(_ title: String, color: Color) -> some View {
        HStack {
            WireLabel(title, color: color)
            Spacer()
        }
        .padding(.horizontal, layout.gutter)
        .padding(.vertical, 9)
        .background(Theme.surfaceHigh.opacity(0.5))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(title)
    }

    // MARK: - Multi-select batch approval

    /// ⌘-selected actions that can be batch-queued: pending drafted sends,
    /// not "maybe", not high-risk. Anything else is incompatible and keeps
    /// the batch bar hidden.
    private var batchSelectedActions: [AgentAction] {
        items.compactMap { item -> AgentAction? in
            guard multiSelectedIds.contains(item.id),
                  case .agentAction(let action) = item,
                  action.statusEnum == .pending,
                  !action.isMaybe,
                  action.riskEnum != .high,
                  action.kindEnum == .reply || action.kindEnum == .ack
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
            Button("QUEUE \(actions.count)") {
                for action in actions {
                    appState.stageManualApprove(action)
                }
                resolvedInSession += actions.count
                multiSelectedIds.removeAll()
            }
            .buttonStyle(PaperButtonStyle(prominent: true, labelFont: Theme.mono(11, weight: .bold), tracking: 0.4))
            .accessibilityLabel("Queue \(actions.count) selected sends")
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
                Text(c.conversationName)
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
            Text(appState.briefs.isEmpty ? "No actions yet" : "You're clear")
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
            appState.stageManualApprove(a)
            resolvedInSession += 1
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
            resolvedInSession += 1
        case .owedReply(let r):
            OwedReplyStore.dismiss(r.id)
            appState.reloadOwedReplies()
            appState.showReceipt("Dismissed owed reply.", actionTitle: "Undo") {
                OwedReplyStore.undismiss(r.id)
                appState.reloadOwedReplies()
                appState.recordUndo()
            }
            resolvedInSession += 1
        }
    }

    // E key — enter inline edit mode on the selected AgentAction card
    private func editSelected() {
        guard let idx = selectedIndex, idx < items.count else { return }
        let item = items[idx]
        if case .agentAction = item {
            editingItemId = (editingItemId == item.id) ? nil : item.id
        }
    }

    private func undoLastStaged() {
        // Find the most recently STAGED (not most recently created) action and
        // cancel it. `agentActions` is ordered by createdAt, so with 2+ actions
        // queued (batch approve), `.first(where: scheduled)` picked whichever
        // had the newest createdAt — not whichever the user actually staged
        // last. And `scheduledAt` alone doesn't fix it either: it's the fire
        // time, and manual (5s window) vs delegated (30s window) sends staged
        // seconds apart can fire in the opposite order. The true staging
        // moment is scheduledAt minus its own window.
        let staged = appState.agentActions
            .filter { $0.statusEnum == .scheduled }
            .max { lhs, rhs in
                let lhsStagedAt = (lhs.scheduledAt ?? .distantPast).addingTimeInterval(-(lhs.scheduledWindow ?? 0))
                let rhsStagedAt = (rhs.scheduledAt ?? .distantPast).addingTimeInterval(-(rhs.scheduledWindow ?? 0))
                return lhsStagedAt < rhsStagedAt
            }
        if let staged {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            appState.undoAutoSend(staged)
            resolvedInSession = max(0, resolvedInSession - 1)
        }
    }
}

// MARK: - Card row

private struct ActCardRow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel

    let item: ActItem
    let layout: DeskLayout
    let isSelected: Bool
    @Binding var isEditingExternal: Bool
    var onResolved: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editText = ""
    @State private var showContextEditor = false

    /// Vermilion is reserved for items still awaiting a decision — matching the
    /// "Needs your decision" section, not every person-waiting item. A drafted
    /// reply that's merely Ready to send is not an emergency.
    private var needsDecision: Bool {
        switch item {
        case .agentAction(let action):
            return action.isMaybe || action.riskEnum == .high
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
        // Sync the external "E key pressed" signal into the local edit state
        .onChange(of: isEditingExternal) { _, newVal in
            if newVal && !isEditing {
                if case .agentAction(let a) = item {
                    editText = a.replyPayload?.draftText ?? a.title
                    isEditing = true
                }
            } else if !newVal && isEditing {
                isEditing = false
            }
        }
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

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 6) {
            ServiceStamp(service: item.service, size: 20)
            // Serif anchor — without it Act was the one screen with no editorial
            // identity, reading as a terminal next to Digests' newspaper.
            Text(item.name)
                .font(Theme.display(14.5))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if item.isStale {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                    Text("\(item.ageHours / 24)d waiting")
                        .font(Theme.mono(10, weight: .semibold))
                }
                .foregroundStyle(Theme.signal)
            } else {
                Text(relativeTime)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
            }
            if case .agentAction(let action) = item, action.isMaybe {
                WireLabel("Maybe", color: Theme.standby)
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

            if isEditing, case .agentAction = item {
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

    // MARK: Detail (expanded when selected)

    @ViewBuilder
    private var detailRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Reasoning context — why the agent surfaced this
            switch item {
            case .agentAction(let a) where !a.reasoning.isEmpty:
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "brain")
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

            // Chat-to-customize button (only for conversations that support drafting)
            Group {
                customizeButton
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var customizeButton: some View {
        switch item {
        case .agentAction(let a)
            where a.kindEnum == .reply || a.kindEnum == .followUp || a.kindEnum == .ack:
            if layout == .compact {
                VStack(alignment: .leading, spacing: 4) {
                    customizeReplyButton(service: a.service, conversationID: a.conversationId, displayName: a.conversationName)
                    customizeLaneButton(name: a.conversationName)
                }
            } else {
                HStack(spacing: 6) {
                    customizeReplyButton(service: a.service, conversationID: a.conversationId, displayName: a.conversationName)
                    customizeLaneButton(name: a.conversationName)
                }
            }
        case .owedReply(let r):
            if layout == .compact {
                VStack(alignment: .leading, spacing: 4) {
                    if !isDraftingDisabled(r) {
                        customizeReplyButton(service: r.service, conversationID: r.conversationId, displayName: r.conversationName,
                                             title: "Chat to compose →")
                    }
                    customizeLaneButton(name: r.conversationName)
                }
            } else {
                HStack(spacing: 6) {
                    if !isDraftingDisabled(r) {
                        customizeReplyButton(service: r.service, conversationID: r.conversationId, displayName: r.conversationName,
                                             title: "Chat to compose →")
                    }
                    customizeLaneButton(name: r.conversationName)
                }
            }
        default:
            customizeLaneButton(name: item.name)
        }
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
            } else if isEditing {
                HStack(spacing: 6) {
                    actionButton("SAVE", tint: Theme.standby) {
                        appState.editAction(a, newText: editText)
                        isEditing = false
                        isEditingExternal = false
                    }
                    actionButton("CANCEL") {
                        isEditing = false
                        isEditingExternal = false
                    }
                }
            } else if layout == .compact {
                VStack(alignment: .leading, spacing: 6) {
                    approveButton(a)
                    HStack(spacing: 6) {
                        editButton(a)
                        skipButton(a)
                    }
                }
            } else {
                approveButton(a)
                editButton(a)
                skipButton(a)
            }
        case .owedReply(let r):
            if layout == .compact {
                VStack(alignment: .leading, spacing: 6) {
                    if !isDraftingDisabled(r) {
                        replyButton(r)
                    }
                    HStack(spacing: 6) {
                        snoozeButton(r)
                        dismissButton(r)
                    }
                }
            } else {
                if !isDraftingDisabled(r) {
                    replyButton(r)
                }
                snoozeButton(r)
                dismissButton(r)
            }
        }
    }

    // MARK: - Button sub-components

    private func approveButton(_ action: AgentAction) -> some View {
        Button("QUEUE SEND") {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
            appState.stageManualApprove(action)
            onResolved?()
        }
        .buttonStyle(PaperButtonStyle(prominent: true, labelFont: Theme.mono(11, weight: .bold), tracking: 0.4))
        .help("Queue send (⌘Return)")
        .accessibilityLabel("Queue suggested send to \(action.conversationName)")
        .accessibilityHint("Sends in 5 seconds unless undone. Keyboard: Command Return.")
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
        .buttonStyle(PrimaryActionStyle(tint: Theme.standby))
    }

    private func scheduledBar(_ action: AgentAction) -> some View {
        ScheduledCountdownBar(action: action) {
            appState.undoAutoSend(action)
        }
    }

    private func editButton(_ action: AgentAction) -> some View {
        actionButton("Edit") {
            editText = action.replyPayload?.draftText ?? action.payload
            isEditing = true
            isEditingExternal = true
        }
    }

    private func skipButton(_ action: AgentAction) -> some View {
        actionButton("Skip") {
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
        actionButton("Dismiss") {
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

    private func customizeReplyButton(service: String,
                                      conversationID: String,
                                      displayName: String,
                                      title: String = "Draft in chat") -> some View {
        Button(title) {
            chatViewModel.prepareReply(
                service: service,
                conversationID: conversationID,
                displayName: displayName
            )
        }
        .buttonStyle(WireActionStyle(tint: Theme.textSecondary, sansLabel: true))
        .accessibilityLabel("Open chat to draft a reply for \(displayName)")
    }

    private func customizeLaneButton(name: String) -> some View {
        Button("Lane settings") { showContextEditor = true }
            .buttonStyle(WireActionStyle(sansLabel: true))
            .accessibilityLabel("Edit priority and delegation settings for \(name)")
    }

    private func actionButton(_ title: String, tint: Color = Theme.textTertiary, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(WireActionStyle(tint: tint, sansLabel: true))
    }

    // MARK: - Helpers

    private func isDraftingDisabled(_ reply: OwedReply) -> Bool {
        // Render path (called per row per body eval) — read the in-memory cache
        // only. fetchConversationContext would fall through to a synchronous DB
        // read AND write @Published state from inside a view update on a miss.
        // The cache is bulk-populated by reloadOwedReplies/reloadAgentActions.
        appState.cachedConversationContext(service: reply.service, conversationId: reply.conversationId)?
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

    private var primaryAccessibilityActionName: String {
        switch item {
        case .agentAction(let a):
            return a.statusEnum == .scheduled ? "Undo scheduled send" : "Queue send"
        case .owedReply:
            return "Compose reply"
        }
    }

    private func performPrimaryAccessibilityAction() {
        switch item {
        case .agentAction(let a):
            if a.statusEnum == .scheduled {
                appState.undoAutoSend(a)
            } else {
                appState.stageManualApprove(a)
                onResolved?()
            }
        case .owedReply(let r):
            guard !isDraftingDisabled(r) else { return }
            chatViewModel.prepareReply(service: r.service, conversationID: r.conversationId, displayName: r.conversationName)
        }
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
                    .accessibilityLabel("Undo — cancel this send")
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
