// LLMessenger/UI/BriefListView.swift
import SwiftUI

struct BriefListView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            SidebarHeaderView()

            Divider().background(Theme.border)

            // Brief list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(appState.briefGroups, id: \.id) { group in
                        SectionHeaderView(label: group.label)
                        ForEach(group.briefs, id: \.id) { brief in
                            BriefRowView(brief: brief,
                                         isSelected: appState.selectedBriefID == brief.id)
                                .onTapGesture {
                                    appState.selectedBriefID = brief.id
                                    appState.markAsOpen(briefID: brief.id!)
                                    Task { try? await chatViewModel.loadBrief(brief) }
                                }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Subviews

private struct SidebarHeaderView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            // Anthropic wordmark-style logo placeholder
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.accent)
                    .frame(width: 22, height: 22)
                Text("L")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            Text("LLMessenger")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if appState.unreadCount > 0 {
                Text("\(appState.unreadCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Theme.accent)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 48)   // space for the invisible title bar
        .padding(.bottom, 10)
    }
}

private struct SectionHeaderView: View {
    let label: String

    var body: some View {
        HStack {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .kerning(0.8)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

private struct BriefRowView: View {
    let brief: Brief
    let isSelected: Bool

    var isUnread: Bool { brief.status == "ready" }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Unread / selection indicator
            Rectangle()
                .fill(isUnread && !isSelected ? Theme.accent : Color.clear)
                .frame(width: 2)
                .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(brief.notificationText)
                        .font(.system(size: 12, weight: isUnread ? .semibold : .regular))
                        .foregroundStyle(isUnread ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(brief.createdAt, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
                if let summary = brief.openingSummary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
        }
        .background(isSelected ? Theme.selection : Color.clear)
        .contentShape(Rectangle())
    }
}
