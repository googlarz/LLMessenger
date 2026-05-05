// LLMessenger/UI/BriefHeaderView.swift
import SwiftUI

struct BriefHeaderView: View {
    let brief: Brief

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(brief.notificationText)
                    .font(.headline)
                Spacer()
                Text(brief.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let summary = brief.openingSummary {
                Text(summary)
                    .font(.body)
                    .foregroundStyle(.primary)
            }

            if let episodic = brief.episodicSummary {
                Divider()
                Text("Previous context")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(episodic)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.regularMaterial)
    }
}
