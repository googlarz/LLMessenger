import SwiftUI

struct OutcomeStripView: View {
    let stats: ProductOutcomeStats
    let layout: DeskLayout

    var body: some View {
        if stats.hasSignal {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    WireLabel("Saved", color: Theme.textSecondary)
                    Spacer(minLength: 8)
                    Text(stats.reassuranceLine)
                        .font(Theme.sans(11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { metrics }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], spacing: 8) { metrics }
                }
            }
            .padding(.horizontal, layout.gutter)
            .padding(.vertical, layout == .compact ? 9 : 11)
            .background(Theme.sidebar)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
        }
    }

    @ViewBuilder
    private var metrics: some View {
        OutcomeMetric(value: stats.threadsSummarized, label: "threads")
        OutcomeMetric(value: stats.quietThreadCount + stats.heldBackCount, label: "noise cut")
        OutcomeMetric(value: stats.totalResolved, label: "handled")
        OutcomeMetric(value: stats.openCommitmentCount, label: "open")
    }

    private var accessibilityText: String {
        "Saved this week. \(stats.reassuranceLine)"
    }
}

private struct OutcomeMetric: View {
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
        .frame(minWidth: 64, alignment: .leading)
    }
}
