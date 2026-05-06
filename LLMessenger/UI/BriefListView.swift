// LLMessenger/UI/BriefListView.swift
import SwiftUI

struct BriefListView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel
    @State private var searchQuery = ""

    private var filteredGroups: [BriefListGroup] {
        guard !searchQuery.isEmpty else { return appState.briefGroups }
        let q = searchQuery.lowercased()
        return appState.briefGroups.compactMap { group in
            let filtered = group.briefs.filter { brief in
                briefTimeLabel(brief).lowercased().contains(q) ||
                briefSyncDate(brief).lowercased().contains(q) ||
                (brief.notificationText.lowercased().contains(q))
            }
            return filtered.isEmpty ? nil :
                BriefListGroup(id: group.id, label: group.label, briefs: filtered)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Widgets below the header bar
            VStack(spacing: 6) {
                NextRefreshWidget()
                SearchBarView(query: $searchQuery)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider().background(Theme.border)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredGroups, id: \.id) { group in
                        SectionHeaderView(label: group.label)
                        ForEach(group.briefs, id: \.id) { brief in
                            BriefRowView(
                                brief: brief,
                                isSelected: appState.selectedBriefID == brief.id
                            )
                            .onTapGesture {
                                appState.selectedBriefID = brief.id
                                appState.markAsOpen(briefID: brief.id!)
                                Task { try? await chatViewModel.loadBrief(brief) }
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

    private func briefTimeLabel(_ brief: Brief) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: brief.createdAt)
    }

    private func briefSyncDate(_ brief: Brief) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f.string(from: brief.createdAt)
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
        let m = secs / 60
        let s = secs % 60
        return String(format: "%dm %02ds", m, s)
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

            TextField("Search", text: $query)
                .font(.system(size: 13))
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(focused ? Theme.accent : Theme.border, lineWidth: 1)
        )
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
            // Active indicator bar
            Rectangle()
                .fill(isSelected ? Theme.accent : Color.clear)
                .frame(width: 2)

            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    // Row 1: sync date + sync time
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(syncDate)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text(syncTime)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                            .monospacedDigit()
                    }
                    // Row 2: time range · relative
                    HStack(spacing: 3) {
                        Text(timeRange)
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

    private var timeRange: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: brief.createdAt)
    }
}

// MARK: - Settings button

private struct SettingsButtonView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Button {
            appState.onOpenSettings?()
        } label: {
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
