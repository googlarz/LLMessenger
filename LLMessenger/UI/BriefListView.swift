// LLMessenger/UI/BriefListView.swift
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
            VStack(spacing: 6) {
                NextRefreshWidget()
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
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if dateFrom != nil || dateTo != nil {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                    Text(dateRangeLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button { dateFrom = nil; dateTo = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(Theme.accentMuted)
            }

            Divider().background(Theme.border)

            if !searchQuery.isEmpty {
                SearchResultsView(messageResults: searchResults,
                                  briefResults: searchBriefResults,
                                  isSearching: isSearching)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Pinned section
                        let pinned = appState.pinnedBriefs
                        if !pinned.isEmpty {
                            SectionHeaderView(label: "📌 Pinned")
                            ForEach(pinned, id: \.id) { brief in
                                BriefRowView(brief: brief,
                                             isSelected: appState.selectedBriefID == brief.id)
                                    .onTapGesture { selectBrief(brief) }
                                    .contextMenu { briefContextMenu(brief) }
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
                            }
                        }
                    }
                }
            }

            Divider().background(Theme.border)
            SettingsButtonView()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
    }

    // MARK: - Helpers

    private func selectBrief(_ brief: Brief) {
        guard let id = brief.id else { return }
        appState.selectedBriefID = id
        appState.markAsOpen(briefID: id)
        // Cancel any in-flight load so a rapid second tap doesn't race and leave
        // brief A's threadItems displayed while selectedBriefID points to brief B.
        loadTask?.cancel()
        loadTask = Task { try? await chatViewModel.loadBrief(brief) }
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
                .font(.system(size: 14))
                .foregroundStyle(isActive ? Theme.accent : Theme.textTertiary)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .background(isActive ? Theme.accentMuted : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
            Text("Filter by Date")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: 8) {
                Button("Last 7 days")  { applyQuick(days: 7) }
                Button("Last 30 days") { applyQuick(days: 30) }
                Button("Last 90 days") { applyQuick(days: 90) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Theme.accent)

            Divider().background(Theme.border)

            DatePicker("From", selection: $localFrom, displayedComponents: .date)
            DatePicker("To",   selection: $localTo,   displayedComponents: .date)

            HStack {
                Button("Clear") { dateFrom = nil; dateTo = nil }
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Apply") {
                    dateFrom = Calendar.current.startOfDay(for: localFrom)
                    dateTo   = Calendar.current.date(bySettingHour: 23, minute: 59,
                                                     second: 59, of: localTo) ?? localTo
                }
                .foregroundStyle(Theme.accent)
            }
            .font(.system(size: 12, weight: .medium))
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 260)
        .background(Theme.surface)
    }

    private func applyQuick(days: Int) {
        dateFrom = Calendar.current.startOfDay(
            for: Date().addingTimeInterval(-Double(days) * 86400))
        dateTo = nil
    }
}

// MARK: - Next refresh countdown widget

private struct NextRefreshWidget: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.accentMuted)
                    .frame(width: 28, height: 28)
                Image(systemName: "clock")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("NEXT REFRESH")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .tracking(0.5)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(countdownText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    private var countdownText: String {
        guard let next = appState.nextPollDate else { return "—" }
        let secs = max(0, Int(next.timeIntervalSinceNow))
        if secs == 0 { return "Now" }
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
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search messages & briefs", text: $query)
                .font(.system(size: 13))
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(focused ? Theme.accent : Theme.border, lineWidth: 1))
        .animation(.easeInOut(duration: 0.12), value: focused)
    }
}

// MARK: - Section header

private struct SectionHeaderView: View {
    let label: String
    var body: some View {
        HStack {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .kerning(0.6)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 3)
    }
}

// MARK: - Brief row

private struct BriefRowView: View {
    let brief: Brief
    let isSelected: Bool

    var isUnread: Bool { brief.status == "ready" }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Rectangle()
                .fill(isSelected ? Theme.accent : Color.clear)
                .frame(width: 2)
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(syncDate)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text(syncTime)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                            .monospacedDigit()
                        if brief.pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.accent.opacity(0.7))
                        }
                    }
                    HStack(spacing: 3) {
                        Text(syncDate)
                        Text("·")
                        Text(brief.createdAt, style: .relative)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
                }
                Spacer(minLength: 4)
                if isUnread {
                    Circle()
                        .fill(isSelected ? Theme.accent : Theme.accent.opacity(0.7))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .padding(.vertical, 9)
        }
        .background(isSelected ? Theme.surfaceHigh : Color.clear)
        .contentShape(Rectangle())
    }

    private var syncDate: String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f.string(from: brief.createdAt)
    }

    private var syncTime: String {
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
            HStack(spacing: 10) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                Text("Settings")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
