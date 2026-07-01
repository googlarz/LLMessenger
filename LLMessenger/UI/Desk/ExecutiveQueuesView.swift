import SwiftUI

struct ExecutiveQueuesView: View {
    let owedReplies: [OwedReply]
    let commitments: [Commitment]
    let tasks: [BriefTask]
    let actions: [AgentAction]

    private var mine: [Commitment] {
        commitments.filter { $0.directionEnum == .iOwe }
    }

    private var theirs: [Commitment] {
        commitments.filter { $0.directionEnum == .theyOwe }
    }

    private var decisions: [AgentAction] {
        actions.filter { $0.isMaybe || $0.kindEnum == .calendarHold || $0.kindEnum == .rsvp }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                WireLabel("Executive view", color: Theme.textSecondary)
                Spacer()
                Text(total == 0 ? "CLEAR" : "\(total) OPEN")
                    .font(Theme.mono(9.5, weight: .semibold))
                    .foregroundStyle(total == 0 ? Theme.ok : Theme.standby)
            }

            if total == 0 {
                Text("No tracked replies, promises, waiting-on-others, or decisions are open.")
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    queueRow("People waiting on me", count: owedReplies.count, sample: owedReplies.first?.conversationName, color: Theme.signal)
                    Rule()
                    queueRow("Promises I made", count: mine.count + tasks.count, sample: mine.first?.what ?? tasks.first?.text, color: Theme.standby)
                    Rule()
                    queueRow("Waiting on others", count: theirs.count, sample: theirs.first?.conversationName, color: Theme.textSecondary)
                    Rule()
                    queueRow("Needs decision", count: decisions.count, sample: decisions.first?.title, color: Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 12)
        .background(Theme.surface.opacity(0.42))
        .accessibilityElement(children: .combine)
    }

    private var total: Int {
        owedReplies.count + mine.count + theirs.count + tasks.count + decisions.count
    }

    private func queueRow(_ title: String, count: Int, sample: String?, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("\(count)")
                .font(Theme.mono(14, weight: .bold))
                .foregroundStyle(count == 0 ? Theme.textTertiary : color)
                .monospacedDigit()
                .frame(width: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.sans(12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let sample, count > 0 {
                    Text(sample)
                        .font(Theme.sans(11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }
}
