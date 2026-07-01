import SwiftUI

struct LearningReceiptsView: View {
    let metrics: ProductLoveMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                WireLabel("Learning", color: metrics.hasLearningSignal ? Theme.ok : Theme.textTertiary)
                Spacer()
                Text("\(metrics.priorityCorrections + metrics.quietedThreads)")
                    .font(Theme.mono(11, weight: .bold))
                    .foregroundStyle(metrics.hasLearningSignal ? Theme.ok : Theme.textTertiary)
                    .monospacedDigit()
            }
            Text(metrics.learningReceipt)
                .font(Theme.sans(11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text(metrics.learningNextStep)
                .font(Theme.sans(11.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 10)
        .background(Theme.sidebar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(metrics.learningReceipt)
    }
}
