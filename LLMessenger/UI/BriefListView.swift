// LLMessenger/UI/BriefListView.swift
//
// The archive drawer: search, date filter, needs-reply triage, and the brief
// history grouped by day. Rows read like an index — mono dateline, headline,
// vermilion dot for unread.

import SwiftUI

struct BriefListView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel
    @State private var searchQuery = ""
    @State private var dateFrom: Date? = nil
    @State private var dateTo: Date? = nil
    @State private var showDateFilter = false
    @State private var searchResults: [MessageSearchResult] = []
    @State private var searchBriefResults: [Brief] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var loadTask: Task<Void, Never>? = nil
    @State private var needsReplyCards: [(card: BriefCardRecord, briefCreatedAt: Date)] = []
    @State private var showArchivedSection = false
    @State private var snoozeTargetBriefID: Int64? = nil
    @State private var showSnoozePopover = false

    var filteredGroups: [BriefListGroup] {
        appState.briefGroups(from: dateFrom, to: dateTo)
            .map { group in
                BriefListGroup(id: group.id, label: group.label,
                               briefs: group.briefs.filter { !$0.pinned })
            }
            .filter { !$0.briefs.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                NextRefreshLine()
                HStack(spacing: 6) {
                    SearchBarView(query: $searchQuery)
                        .onChange(of: searchQuery) { q in performSearch(q) }
                    DateFilterButton(isActive: dateFrom != nil || dateTo != nil,
                                     showPopover: $showDateFilter)
                        .popover(isPresented: $showDateFilter, arrowEdge: .bottom) {
                            DateFilterPopover(dateFrom: $dateFrom, dateTo: $dateTo)
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if dateFrom != nil || dateTo != nil {
                HStack(spacing: 6) {
                    WireLabel(dateRangeLabel, color: Theme.textSecondary)
                    Spacer()
                    Button { dateFrom = nil; dateTo = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear date filter")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Theme.surface)
            }

            Rule()

            if !searchQuery.isEmpty {
                SearchResultsView(messageResults: searchResults,
                                  briefResults: searchBriefResults,
                                  isSearching: isSearching)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Tasks section
                        if !appState.tasks.isEmpty {
                            TaskListView()
                        }

                        // Needs Reply triage section
                        let unhandled = needsReplyCards.filter {
                            !appState.isCardHandled(briefID: $0.card.briefId, cardID: $0.card.id)
                        }
                        if !unhandled.isEmpty {
                            NeedsReplySection(
                                cards: unhandled,
                                onTap: { card in
                                    // Select the brief containing this card
                                    if let brief = appState.briefs.first(where: { $0.id == card.briefId }) {
                                        selectBrief(brief)
                                    }
                                }
                            )
                        }

                        // Empty state
                        if filteredGroups.isEmpty && appState.pinnedBriefs.isEmpty && needsReplyCards.isEmpty && searchQuery.isEmpty {
                            VStack(spacing: 10) {
                                Spacer().frame(height: 28)
                                WireLabel("Archive empty")
                                Text("Your first brief lands\nafter the next poll.")
                                    .font(Theme.display(14))
                                    .foregroundStyle(Theme.textSecondary)
                                    .multilineTextAlignment(.center)
                                Text("Check Settings to confirm your\nservices are connected.")
                                    .font(Theme.sans(11.5))
                                    .foregroundStyle(Theme.textTertiary)
                                    .multilineTextAlignment(.center)
                                Button("OPEN SETTINGS") { appState.onOpenSettings?() }
                                    .buttonStyle(WireActionStyle(tint: Theme.textPrimary))
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)
                        }

                        // Pinned section
                        let pinned = appState.pinnedBriefs
                        if !pinned.isEmpty {
                            SectionHeaderView(label: "Pinned")
                            ForEach(pinned, id: \.id) { brief in
                                BriefRowView(brief: brief,
                                             isSelected: appState.selectedBriefID == brief.id)
                                    .onTapGesture { selectBrief(brief) }
                                    .contextMenu { briefContextMenu(brief) }
                                    .swipeActions(edge: .trailing) { briefSwipeActions(brief) }
                            }
                        }

                        // Date-grouped unpinned briefs
                        ForEach(filteredGroups, id: \.id) { group in
                            SectionHeaderView(label: group.label)
                            ForEach(group.briefs, id: \.id) { brief in
                                BriefRowView(brief: brief,
                                             isSelected: appState.selectedBriefID == brief.id)
                                    .onTapGesture { selectBrief(brief) }
                                    .contextMenu { briefContextMenu(brief) }
                                    .swipeActions(edge: .trailing) { briefSwipeActions(brief) }
                            }
                        }

                        // Archived section
                        let archived = appState.archivedBriefs
                        if !archived.isEmpty {
                            Button {
                                withAnimation(Theme.spring) { showArchivedSection.toggle() }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(Theme.textTertiary)
                                        .rotationEffect(.degrees(showArchivedSection ? 90 : 0))
                                    WireLabel("Filed away (\(archived.count))")
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if showArchivedSection {
                                ForEach(archived, id: \.id) { brief in
                                    BriefRowView(brief: brief,
                                                 isSelected: appState.selectedBriefID == brief.id)
                                        .onTapGesture { selectBrief(brief) }
                                        .swipeActions(edge: .trailing) {
                                            Button {
                                                if let id = brief.id { appState.unarchiveBrief(id) }
                                            } label: {
                                                Label("Unarchive", systemImage: "arrow.uturn.backward")
                                            }
                                            .tint(.blue)
                                        }
                                }
                            }
                        }
                    }
                }
            }

            Rule()
            SettingsButtonView()
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        }
        .onAppear { refreshNeedsReply(); appState.refreshTasks() }
        .onChange(of: appState.briefs.map { $0.id }) { _ in refreshNeedsReply(); appState.refreshTasks() }
        .onChange(of: appState.handledCardKeys) { _ in refreshNeedsReply() }
    }

    // MARK: - Helpers

    private func refreshNeedsReply() {
        let raw = appState.fetchNeedsReplyCards()
        // Deduplicate: keep the newest card per service+conversationId
        var seen = Set<String>()
        needsReplyCards = raw.filter { item in
            let key = "\(item.card.service)|\(item.card.conversationId)"
            return seen.insert(key).inserted
        }
    }

    private func selectBrief(_ brief: Brief) {
        appState.lastError = nil
        guard let id = brief.id else { return }
        appState.selectedBriefID = id
        appState.markAsOpen(briefID: id)
        chatViewModel.inputText = ""
        chatViewModel.pendingTarget = nil
        // Cancel any in-flight load so a rapid second tap doesn't race and leave
        // brief A's threadItems displayed while selectedBriefID points to brief B.
        loadTask?.cancel()
        loadTask = Task { try? await chatViewModel.loadBrief(brief) }
    }

    @ViewBuilder
    private func briefSwipeActions(_ brief: Brief) -> some View {
        Button {
            if let id = brief.id { appState.archiveBrief(id) }
        } label: {
            Label("Archive", systemImage: "archivebox")
        }
        .tint(.orange)

        Button {
            snoozeTargetBriefID = brief.id
            showSnoozePopover = true
        } label: {
            Label("Snooze", systemImage: "moon.zzz")
        }
        .tint(.indigo)
        .popover(isPresented: $showSnoozePopover) {
            if let briefID = snoozeTargetBriefID,
               let brief = appState.briefs.first(where: { $0.id == briefID }) {
                SnoozePickerView(brief: brief) { date in
                    appState.snoozeBrief(id: briefID, until: date)
                    NotificationManager.scheduleSnoozeNotification(
                        briefID: briefID,
                        headline: brief.notificationText,
                        at: date
                    )
                    showSnoozePopover = false
                }
            }
        }
    }

    @ViewBuilder
    private func briefContextMenu(_ brief: Brief) -> some View {
        if brief.pinned {
            Button("Unpin") {
                if let id = brief.id { appState.setPinnedBrief(briefID: id, pinned: false) }
            }
        } else {
            Button("Pin") {
                let pinnedCount = appState.pinnedBriefs.count
                if pinnedCount >= 10 {
                    appState.lastError = "Cannot pin more than 10 briefs. Unpin one first."
                } else {
                    if let id = brief.id { appState.setPinnedBrief(briefID: id, pinned: true) }
                }
            }
        }
        Divider()
        Button("Mark as Read") {
            if let id = brief.id { appState.markAsOpen(briefID: id) }
        }
    }

    private func performSearch(_ query: String) {
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            searchBriefResults = []
            return
        }
        isSearching = true
        searchTask = Task {
            // Debounce: FTS5 ran synchronously on every keystroke.
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            do {
                let msgResults = try appState.repository.searchMessages(query: query)
                let briefResults = try appState.repository.searchBriefs(query: query)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    searchResults = msgResults
                    searchBriefResults = briefResults
                    isSearching = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { isSearching = false }
            }
        }
    }

    private var dateRangeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        let fromStr = dateFrom.map { f.string(from: $0) } ?? "…"
        let toStr   = dateTo.map   { f.string(from: $0) } ?? "now"
        return "\(fromStr) – \(toStr)"
    }
}

// MARK: - Date filter button

private struct DateFilterButton: View {
    let isActive: Bool
    @Binding var showPopover: Bool

    var body: some View {
        Button { showPopover.toggle() } label: {
            Image(systemName: isActive ? "calendar.badge.clock" : "calendar")
                .font(.system(size: 13))
                .foregroundStyle(isActive ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: Theme.controlRadius)
                .fill(isActive ? Theme.surfaceHigh : Color.clear)
        )
        .help("Filter by date range")
    }
}

// MARK: - Date filter popover

private struct DateFilterPopover: View {
    @Binding var dateFrom: Date?
    @Binding var dateTo: Date?
    @State private var localFrom = Date().addingTimeInterval(-7 * 86400)
    @State private var localTo   = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WireLabel("Filter by date")

            HStack(spacing: 12) {
                Button("7 DAYS")  { applyQuick(days: 7) }
                Button("30 DAYS") { applyQuick(days: 30) }
                Button("90 DAYS") { applyQuick(days: 90) }
            }
            .buttonStyle(WireActionStyle())

            Rule()

            DatePicker("From", selection: $localFrom, displayedComponents: .date)
            DatePicker("To",   selection: $localTo,   displayedComponents: .date)

            HStack {
                Button("Clear") { dateFrom = nil; dateTo = nil }
                    .buttonStyle(WireActionStyle())
                Spacer()
                Button("Apply") {
                    dateFrom = Calendar.current.startOfDay(for: localFrom)
                    dateTo   = Calendar.current.date(bySettingHour: 23, minute: 59,
                                                     second: 59, of: localTo) ?? localTo
                }
                .buttonStyle(PaperButtonStyle(prominent: true))
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    private func applyQuick(days: Int) {
        dateFrom = Calendar.current.startOfDay(
            for: Date().addingTimeInterval(-Double(days) * 86400))
        dateTo = nil
    }
}

// MARK: - Next refresh line

private struct NextRefreshLine: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack {
            WireLabel("Next brief")
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(countdownText)
                    .font(Theme.mono(11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 2)
    }

    private var countdownText: String {
        guard let next = appState.nextPollDate else { return "—" }
        let secs = max(0, Int(next.timeIntervalSinceNow))
        if secs == 0 { return "now" }
        return String(format: "%dm %02ds", secs / 60, secs % 60)
    }
}

// MARK: - Search bar

private struct SearchBarView: View {
    @Binding var query: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search the archive", text: $query)
                .font(Theme.sans(12.5))
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.controlRadius)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.controlRadius)
                .strokeBorder(focused ? Theme.textSecondary : Theme.border,
                              lineWidth: focused ? 1 : Theme.hairline)
        )
        .animation(Theme.quick, value: focused)
    }
}

// MARK: - Section header

private struct SectionHeaderView: View {
    let label: String
    var body: some View {
        HStack {
            WireLabel(label)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

// MARK: - Brief row

private struct BriefRowView: View {
    let brief: Brief
    let isSelected: Bool

    @State private var hovering = false

    var isUnread: Bool { brief.status == "ready" }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Selection is interaction, not urgency — the rule is paper, not vermilion.
            Rectangle()
                .fill(isSelected ? Theme.textPrimary : Color.clear)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Day lives in the section header — the row carries time only.
                    Text(timeLabel)
                        .font(Theme.mono(9.5, weight: .semibold))
                        .foregroundStyle(isSelected ? Theme.textSecondary : Theme.textTertiary)
                    if brief.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 4)
                    if isUnread {
                        Circle()
                            .fill(Theme.signal)
                            .frame(width: 6, height: 6)
                    }
                }
                Text(brief.notificationText)
                    .font(Theme.sans(12.5, weight: isUnread ? .semibold : .regular))
                    .foregroundStyle(isUnread || isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
        }
        .background(isSelected ? Theme.selection : hovering ? Theme.surface.opacity(0.6) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
    }

    private var timeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: brief.createdAt)
    }
}

// MARK: - Settings button

private struct SettingsButtonView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Button { appState.onOpenSettings?() } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                WireLabel("Settings", color: Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Snooze picker

private struct SnoozePickerView: View {
    let brief: Brief
    let onSelect: (Date) -> Void

    private var tonight8pm: Date {
        Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date()) ?? Date()
    }

    private var tomorrowMorning: Date {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            WireLabel("Snooze until")
                .padding(.bottom, 6)

            snoozeOption("In 2 hours") { onSelect(Date().addingTimeInterval(2 * 3600)) }
            snoozeOption("Tonight at 8pm") { onSelect(tonight8pm) }
            snoozeOption("Tomorrow morning") { onSelect(tomorrowMorning) }
        }
        .padding(14)
        .frame(width: 200)
    }

    private func snoozeOption(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.sans(13))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Needs Reply triage section

private struct NeedsReplySection: View {
    @EnvironmentObject var appState: AppState
    let cards: [(card: BriefCardRecord, briefCreatedAt: Date)]
    let onTap: (BriefCardRecord) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                WireLabel("Needs reply", color: Theme.signal)
                Spacer()
                Text("\(cards.count)")
                    .font(Theme.mono(10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ForEach(cards, id: \.card.id) { item in
                Button { onTap(item.card) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Theme.signal.frame(width: 2)
                            .clipShape(RoundedRectangle(cornerRadius: 1))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                ServiceStamp(service: item.card.service, size: 14)
                                Text((item.card.conversationTitle ?? Theme.serviceName(item.card.service)).uppercased())
                                    .font(Theme.mono(9, weight: .semibold))
                                    .tracking(0.8)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(briefAge(item.briefCreatedAt))
                                    .font(Theme.mono(9))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Text(item.card.headline)
                                .font(Theme.sans(11.5))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Rule()
                .padding(.top, 8)
        }
    }

    private func briefAge(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 3600  { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
}
