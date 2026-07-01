import SwiftUI

struct TodaySummaryView: View {
    @EnvironmentObject var appState: AppState
    let layout: DeskLayout

    private var activeActions: Int {
        appState.agentActions.filter { !$0.isMaybe }.count
    }

    private var promiseCount: Int {
        appState.commitments.count + appState.tasks.count
    }

    private var waitingCount: Int {
        appState.owedCount
    }

    private var isClear: Bool {
        waitingCount == 0 && activeActions == 0 && promiseCount == 0
    }

    private var latestBrief: Brief? {
        appState.briefs.sorted { $0.createdAt > $1.createdAt }.first
    }

    private var latestDigestStats: (reply: Int, review: Int, quiet: Int) {
        guard let json = BriefJSON.decodeLenient(from: latestBrief?.openingSummary) else {
            return (0, 0, 0)
        }
        let reply = json.cards.filter(\.needsReply).count
        let review = json.cards.filter { !$0.needsReply && $0.priority == "high" }.count
        let quiet = json.cards.filter { !$0.needsReply && ($0.priority == "low" || $0.collapsed) }.count
        return (reply, review, quiet)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                WireLabel(isClear ? "Clear" : "Today", color: isClear ? Theme.ok : Theme.signal)
                Spacer(minLength: 8)
                if let next = appState.nextPollDate {
                    Text("NEXT \(next.todayRelativeLabel.uppercased())")
                        .font(Theme.mono(9.5, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }

            Text(headline)
                .font(Theme.display(layout == .compact ? 18 : 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if layout == .regular || !isClear {
                Text(detail)
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if layout == .regular || !isClear {
                HStack(spacing: 8) {
                    TodayMetric(value: waitingCount, label: "queue", color: waitingCount == 0 ? Theme.textTertiary : Theme.signal)
                    TodayMetric(value: activeActions, label: "ready", color: activeActions == 0 ? Theme.textTertiary : Theme.standby)
                    TodayMetric(value: promiseCount, label: "promised", color: promiseCount == 0 ? Theme.textTertiary : Theme.textSecondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, layout.gutter)
        .padding(.top, layout == .compact && isClear ? 9 : 12)
        .padding(.bottom, layout == .compact && isClear ? 10 : 13)
        .background(isClear ? Theme.ok.opacity(0.045) : Theme.surface.opacity(0.42))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var headline: String {
        if isClear {
            return "Caught up from the latest sync."
        }
        if waitingCount > 0 {
            return "\(waitingCount) \(waitingCount == 1 ? "person is" : "people are") waiting on you."
        }
        if activeActions > 0 {
            return "\(activeActions) prepared \(activeActions == 1 ? "action" : "actions") ready to review."
        }
        return "\(promiseCount) open \(promiseCount == 1 ? "promise" : "promises") to keep."
    }

    private var detail: String {
        let stats = latestDigestStats
        if isClear {
            if let latestBrief {
                var parts = ["No tracked replies or promises are open", "last digest \(latestBrief.createdAt.todayRelativeLabel)"]
                if appState.productLoveMetrics.handledCards > 0 {
                    parts.append("\(appState.productLoveMetrics.handledCards) handled all-time")
                }
                if let next = appState.nextPollDate {
                    parts.append("next check \(next.todayRelativeLabel)")
                }
                return parts.joined(separator: " · ") + "."
            }
            return "No tracked replies or promises are open. Your first digest will appear after the next sync."
        }

        var parts: [String] = []
        if stats.reply > 0 {
            parts.append("\(stats.reply) reply-needed")
        }
        if stats.review > 0 {
            parts.append("\(stats.review) review")
        }
        if stats.quiet > 0 {
            parts.append("\(stats.quiet) quiet")
        }
        if appState.heldBackCount > 0 {
            parts.append("\(appState.heldBackCount) held back")
        }
        return parts.isEmpty
            ? "Clear the queue, then you're done for now."
            : "Queue plus latest digest: \(parts.joined(separator: " · "))."
    }

    private var accessibilityText: String {
        "\(headline) \(detail)"
    }
}

private extension Date {
    var todayRelativeLabel: String {
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

private struct TodayMetric: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(value)")
                .font(Theme.mono(13, weight: .bold))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label.uppercased())
                .font(Theme.mono(9.5, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Theme.surfaceHigh.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
