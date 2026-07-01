import SwiftUI

struct ProductHealthView: View {
    let metrics: ProductLoveMetrics
    let stats: ProductOutcomeStats

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                WireLabel("Local health", color: Theme.textSecondary)
                Spacer()
                WireLabel(scoreLabel, color: scoreColor)
            }

            Text(healthLine)
                .font(Theme.sans(11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { metricsRow }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 8)], spacing: 8) { metricsRow }
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 11)
        .background(Theme.sidebar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Local product health. \(healthLine)")
    }

    @ViewBuilder
    private var metricsRow: some View {
        HealthMetric(value: metrics.activeDays, label: "days")
        HealthMetric(value: metrics.openedDigests, label: "opens")
        HealthMetric(value: stats.totalResolved, label: "handled")
        HealthMetric(value: metrics.priorityCorrections + metrics.quietedThreads, label: "taught")
    }

    private var score: Int {
        var value = 0
        if metrics.activeDays >= 2 { value += 25 }
        if metrics.openedDigests > 0 { value += 20 }
        if stats.totalResolved > 0 || metrics.handledCards > 0 { value += 25 }
        if metrics.hasLearningSignal { value += 20 }
        if stats.sourceBackedCardCount > 0 { value += 10 }
        return min(100, value)
    }

    private var scoreLabel: String {
        "\(score)/100"
    }

    private var scoreColor: Color {
        if score >= 80 { return Theme.ok }
        if score >= 50 { return Theme.standby }
        return Theme.textTertiary
    }

    private var healthLine: String {
        if score >= 80 {
            return "The loop is working: repeated opens, clear outcomes, learning signals, and source-backed trust."
        }
        if metrics.openedDigests == 0 {
            return "Open one digest to start measuring habit quality locally."
        }
        if stats.totalResolved == 0 && metrics.handledCards == 0 {
            return "The next unlock is a clear outcome: mark done, queue a reply, or quiet a thread."
        }
        if !metrics.hasLearningSignal {
            return "The next unlock is learning: correct priority or quiet one low-signal thread."
        }
        return "Good signal is forming. Another active day turns it into a habit."
    }
}

private struct HealthMetric: View {
    let value: Int
    let label: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(value)")
                .font(Theme.mono(13, weight: .bold))
                .foregroundStyle(value == 0 ? Theme.textTertiary : Theme.textPrimary)
                .monospacedDigit()
            Text(label.uppercased())
                .font(Theme.mono(9.5, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(minWidth: 70, alignment: .leading)
    }
}
