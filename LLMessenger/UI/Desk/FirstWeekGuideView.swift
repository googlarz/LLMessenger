import SwiftUI

struct FirstWeekGuideView: View {
    let metrics: ProductLoveMetrics
    let suggestions: [ContextSuggestion]
    let onAcceptSuggestion: (ContextSuggestion) -> Void
    let onDismissSuggestion: (ContextSuggestion) -> Void

    private var topSuggestion: ContextSuggestion? {
        suggestions.first { $0.kind == "prioritize" || $0.kind == "keySender" } ?? suggestions.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                WireLabel("First week", color: Theme.textSecondary)
                Spacer()
                WireLabel("Day \(metrics.firstWeekDay)", color: Theme.standby)
            }

            Text(stepLine)
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Open once. Clear what matters. Leave with confidence.")
                .font(Theme.sans(11.5, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                GuideStep(index: 1, label: "Open", done: metrics.openedDigests > 0)
                GuideStep(index: 2, label: "Clear", done: metrics.handledCards > 0)
                GuideStep(index: 3, label: "Teach", done: metrics.hasLearningSignal)
                GuideStep(index: 4, label: "Trust", done: metrics.activeDays >= 2)
            }

            if let topSuggestion {
                Rule()
                HStack(alignment: .top, spacing: 9) {
                    ServiceStamp(service: topSuggestion.service, size: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("VIP candidate: \(topSuggestion.conversationName)")
                            .font(Theme.sans(12.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(topSuggestion.rationale)
                            .font(Theme.sans(11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("MARK VIP") { onAcceptSuggestion(topSuggestion) }
                        .buttonStyle(WireActionStyle(tint: Theme.standby))
                    Button("SKIP") { onDismissSuggestion(topSuggestion) }
                        .buttonStyle(WireActionStyle())
                }
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 12)
        .background(Theme.surface.opacity(0.42))
        .accessibilityElement(children: .contain)
    }

    private var stepLine: String {
        if metrics.openedDigests == 0 {
            return "Start with one digest. The top card shows why it matters and where it came from."
        }
        if metrics.handledCards == 0 {
            return "Clear one card to close the loop and make the next check shorter."
        }
        if !metrics.hasLearningSignal {
            return "Use more, less, or quiet once. The next digest gets more personal."
        }
        if metrics.activeDays < 2 {
            return "Come back tomorrow for a calmer daily check."
        }
        return "Your habit loop is forming: open, clear, teach, leave."
    }
}

private struct GuideStep: View {
    let index: Int
    let label: String
    let done: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(done ? "✓" : "\(index)")
                .font(Theme.mono(10, weight: .bold))
                .foregroundStyle(done ? Theme.ok : Theme.textTertiary)
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(done ? Theme.ok.opacity(0.55) : Theme.border, lineWidth: 1))
            Text(label.uppercased())
                .font(Theme.mono(9.5, weight: .medium))
                .foregroundStyle(done ? Theme.textSecondary : Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
