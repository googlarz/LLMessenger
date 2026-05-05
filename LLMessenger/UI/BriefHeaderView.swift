// LLMessenger/UI/BriefHeaderView.swift
import SwiftUI

struct BriefHeaderView: View {
    let brief: Brief
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title row
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    // Service badge
                    ServiceBadgeView(services: brief.serviceNames)

                    Text(brief.notificationText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    Text(brief.createdAt, style: .date)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if isExpanded, let summary = brief.openingSummary, !summary.isEmpty {
                Divider().background(Theme.border)

                // AI Summary with left accent bar
                HStack(alignment: .top, spacing: 12) {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: 2)
                        .cornerRadius(1)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                            Text("AI Summary")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        Text(summary)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(6)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if let episodic = brief.episodicSummary, !episodic.isEmpty {
                    Divider().background(Theme.border)
                    HStack(alignment: .top, spacing: 12) {
                        Rectangle()
                            .fill(Theme.textTertiary)
                            .frame(width: 2)
                            .cornerRadius(1)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Previous context")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                            Text(episodic)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(4)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Theme.surface)
    }
}

private struct ServiceBadgeView: View {
    let services: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(services, id: \.self) { service in
                Text(service.capitalized)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Theme.accentMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

// MARK: - Brief extension for parsing service names

private extension Brief {
    var serviceNames: [String] {
        guard let data = services.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return arr
    }
}
