import SwiftUI

struct WeeklyRecapView: View {
    let briefs: [Brief]
    let owedCount: Int
    let commitmentsCount: Int

    private var recentBriefs: [Brief] {
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        return briefs.filter { $0.createdAt >= cutoff }
    }

    private var cardStats: (threads: Int, reply: Int, quiet: Int) {
        var threads = 0
        var reply = 0
        var quiet = 0
        for brief in recentBriefs {
            guard let json = BriefJSON.decodeLenient(from: brief.openingSummary) else { continue }
            threads += json.cards.count
            reply += json.cards.filter(\.needsReply).count
            quiet += json.cards.filter { !$0.needsReply && ($0.priority == "low" || $0.collapsed) }.count
        }
        return (threads, reply, quiet)
    }

    var body: some View {
        let stats = cardStats
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                WireLabel("This week", color: Theme.textSecondary)
                Spacer()
                Text(weeklyVerdict.uppercased())
                    .font(Theme.mono(9.5, weight: .semibold))
                    .foregroundStyle(owedCount == 0 ? Theme.ok : Theme.standby)
            }

            Text(recapLine(stats: stats))
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                RecapMetric(value: recentBriefs.count, label: "digests")
                RecapMetric(value: stats.threads, label: "threads")
                RecapMetric(value: stats.reply, label: "replies")
                RecapMetric(value: stats.quiet, label: "quiet")
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 12)
        .background(Theme.surface.opacity(0.42))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(recapLine(stats: stats))
    }

    private var weeklyVerdict: String {
        if owedCount == 0 && commitmentsCount == 0 { return "clear" }
        if owedCount > 0 { return "\(owedCount) waiting" }
        return "\(commitmentsCount) promises"
    }

    private func recapLine(stats: (threads: Int, reply: Int, quiet: Int)) -> String {
        if recentBriefs.isEmpty {
            return "No digests yet this week. Once messages arrive, this will show what LLMessenger kept off your plate."
        }
        if owedCount == 0 && commitmentsCount == 0 {
            return "You're staying on top of people: no open replies or promises right now."
        }
        if owedCount > 0 {
            return "\(owedCount) \(owedCount == 1 ? "person is" : "people are") still waiting; \(stats.quiet) quiet \(stats.quiet == 1 ? "thread" : "threads") stayed out of the way."
        }
        return "\(commitmentsCount) open \(commitmentsCount == 1 ? "promise" : "promises"); \(stats.threads) threads summarized this week."
    }
}

private struct RecapMetric: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(Theme.mono(14, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
            Text(label.uppercased())
                .font(Theme.mono(8.5, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
