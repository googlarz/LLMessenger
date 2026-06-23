// LLMessenger/UI/BriefHeaderView.swift
import SwiftUI

/// The brief masthead — typeset like the front page of a wire digest:
/// kicker line (edition · window · state), serif headline, mono dateline.
struct BriefHeaderView: View {
    let brief: Brief
    let messageCount: Int
    let serviceCount: Int
    let briefCount: Int
    let threadCount: Int
    let peopleCount: Int
    let highPriorityCount: Int
    let failedServices: [String]
    let generationState: BriefGenerationState
    let errorText: String?
    var onRefresh: (() -> Void)? = nil

    @EnvironmentObject var chatViewModel: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                WireLabel("\(briefKind) · \(timeRange)\(stateSuffix)", color: stateColor)
                Spacer()
                HStack(spacing: 6) {
                    Button("What changed?") {
                        chatViewModel.inputText = "What changed since the last digest?"
                        Task { await chatViewModel.send() }
                    }
                    .buttonStyle(WireActionStyle())
                    .help("Ask what changed since the last digest")

                    Button {
                        InstrumentationManager.shared.track(event: .refreshTriggered, metadata: ["source": "header"])
                        onRefresh?()
                    } label: {
                        Text(isWorking ? "Working…" : "Refresh")
                    }
                    .buttonStyle(PaperButtonStyle())
                    .disabled(isWorking)
                    .help("Fetch new messages and rebuild the digest")
                }
            }
            .padding(.bottom, 14)

            Text(actionHeadline)
                .font(Theme.display(27))
                // The all-clear ("Nothing needs you right now.") is an earned, definitive
                // statement — give it full weight; only the truly-empty "No new messages." dims.
                .foregroundStyle((highPriorityCount > 0 || briefCount > 0) ? Theme.textPrimary : Theme.textSecondary)
                .kerning(0.2)
                .padding(.bottom, 8)

            HStack(spacing: 0) {
                datelineItem("\(briefCount)", briefCount == 1 ? "thread" : "threads")
                datelineDot
                datelineItem("\(messageCount)", messageCount == 1 ? "message" : "messages")
                datelineDot
                datelineItem("\(peopleCount)", peopleCount == 1 ? "person" : "people")
                if !failedServices.isEmpty {
                    datelineDot
                    Text("\(failedServices.count) unreachable".uppercased())
                        .font(Theme.labelFont)
                        .tracking(Theme.labelTracking)
                        .foregroundStyle(Theme.standby)
                }
            }

            if !failedServices.isEmpty {
                noticeRow(
                    color: Theme.standby,
                    label: "Partial digest",
                    text: "Could not reach \(failedServices.map { Theme.serviceName($0) }.joined(separator: ", ")) — its threads are missing here."
                )
                .padding(.top, 16)
            }

            if let errorText, !errorText.isEmpty {
                noticeRow(color: Theme.signal, label: "Error", text: errorText)
                    .padding(.top, 12)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 26)
        .padding(.bottom, 20)
    }

    // MARK: - Pieces

    private func datelineItem(_ value: String, _ unit: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(Theme.mono(11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(unit.uppercased())
                .font(Theme.labelFont)
                .tracking(Theme.labelTracking)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var datelineDot: some View {
        Text("·")
            .font(Theme.mono(11))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 7)
    }

    /// Editorial notice: vertical rule + mono label + plain sentence.
    private func noticeRow(color: Color, label: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            color.frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))
            VStack(alignment: .leading, spacing: 3) {
                WireLabel(label, color: color)
                Text(text)
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var isWorking: Bool {
        generationState == .fetching || generationState == .summarizing
    }

    // MARK: - Copy

    /// What the user came here to learn, in priority order.
    private var actionHeadline: String {
        if briefCount == 0 && messageCount == 0 { return "No new messages." }
        if highPriorityCount > 0 {
            return highPriorityCount == 1
                ? "One thing needs you."
                : "\(spelled(highPriorityCount)) things need you."
        }
        // Mirror the "One thing needs you." voice — the affirming negative is its own feature
        // for someone who lives in fear of the missed message.
        if briefCount > 0 { return "Nothing needs you right now." }
        return "\(messageCount) new message\(messageCount == 1 ? "" : "s")."
    }

    private func spelled(_ n: Int) -> String {
        let words = ["", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"]
        return n < words.count ? words[n] : "\(n)"
    }

    private var briefKind: String {
        guard let start = brief.windowStart else { return "Hourly digest" }
        let hours = Int(brief.createdAt.timeIntervalSince(start) / 3600)
        if hours >= 24 * 6 { return "7-day digest" }
        if hours >= 24 { return "\(hours / 24)-day digest" }
        if hours >= 2  { return "\(hours)-hour digest" }
        return "Hourly digest"
    }

    private var timeRange: String {
        let end = brief.createdAt
        let start = brief.windowStart ?? end.addingTimeInterval(-3600)
        let f = DateFormatter()
        let span = end.timeIntervalSince(start)
        if span > 24 * 3600 {
            f.dateFormat = "MMM d"
            return "\(f.string(from: start)) – \(f.string(from: end))"
        }
        f.dateFormat = "HH:mm"
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }

    private var stateSuffix: String {
        switch generationState {
        case .cached, .complete: return ""
        case .fetching: return " · fetching"
        case .summarizing: return " · updating"
        case .partial: return " · partial"
        case .noNewMessages: return " · no new messages"
        case .failed: return " · failed"
        }
    }

    private var stateColor: Color {
        switch generationState {
        case .complete, .cached, .noNewMessages:
            return Theme.textTertiary
        case .fetching, .summarizing:
            return Theme.textSecondary
        case .partial:
            return Theme.standby
        case .failed:
            return Theme.signal
        }
    }
}
