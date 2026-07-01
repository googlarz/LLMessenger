import SwiftUI

struct TrustCockpitView: View {
    let isLLMConfigured: Bool
    let isLocalLLM: Bool
    let sourceBackedCards: Int
    let auditCount: Int
    let queuedSendCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                WireLabel("Trust", color: Theme.textSecondary)
                Spacer()
                WireLabel(isLocalLLM ? "Local" : "Cloud", color: isLocalLLM ? Theme.ok : Theme.standby)
            }

            Text(summary)
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                TrustRow(title: isLocalLLM ? "Messages stay on this Mac" : "Cloud model is active",
                         detail: isLocalLLM ? "Briefs and drafts use a local model." : "Prompts go to the selected provider; network metadata is logged.",
                         color: isLocalLLM ? Theme.ok : Theme.standby)
                Rule()
                TrustRow(title: "No LLMessenger server",
                         detail: "Messages live in the local app database; credentials live in macOS Keychain.",
                         color: Theme.ok)
                Rule()
                TrustRow(title: "\(sourceBackedCards) source-backed \(sourceBackedCards == 1 ? "card" : "cards")",
                         detail: "Digest claims can be opened back to the original messages.",
                         color: Theme.textSecondary)
                Rule()
                TrustRow(title: "\(queuedSendCount) queued \(queuedSendCount == 1 ? "send" : "sends")",
                         detail: "Manual sends wait 5 seconds with undo before delivery.",
                         color: queuedSendCount == 0 ? Theme.textTertiary : Theme.standby)
                Rule()
                TrustRow(title: "\(auditCount) audit \(auditCount == 1 ? "entry" : "entries") today",
                         detail: "Approved and delegated sends are recorded in Activity.",
                         color: auditCount == 0 ? Theme.textTertiary : Theme.textSecondary)
                Rule()
                TrustRow(title: "Per-thread privacy",
                         detail: "Sensitive conversations can be marked local-only or never draft.",
                         color: Theme.textSecondary)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 12)
        .background(Theme.surface.opacity(0.42))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary)
    }

    private var summary: String {
        if !isLLMConfigured {
            return "AI is not configured yet. Demo data is local; real digests begin after setup."
        }
        if isLocalLLM {
            return "Local processing is active, source evidence is visible, sends stay undoable, and sensitive threads can opt out."
        }
        return "Cloud processing is explicit, source evidence is visible, sends stay undoable, and sensitive threads can opt out."
    }
}

private struct TrustRow: View {
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.sans(12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.sans(11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }
}
