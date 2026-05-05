// LLMessenger/UI/BriefHeaderView.swift
import SwiftUI

struct BriefHeaderView: View {
    let brief: Brief
    let messageCount: Int
    let serviceCount: Int
    let threadCount: Int
    let peopleCount: Int
    var onRefresh: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.accentMuted)
                    .frame(width: 40, height: 40)
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("HOURLY BRIEF · \(timeRange)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .tracking(0.5)

                Text("\(messageCount) new messages across \(serviceCount) app\(serviceCount == 1 ? "" : "s")")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .tracking(-0.4)

                Text("Generated just now · \(threadCount) thread\(threadCount == 1 ? "" : "s") · \(peopleCount) \(peopleCount == 1 ? "person" : "people")")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Button {
                onRefresh?()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                    Text("Refresh now")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private var timeRange: String {
        let end = brief.createdAt
        let start = end.addingTimeInterval(-3600)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }
}
