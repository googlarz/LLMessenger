// LLMessenger/UI/BriefHeaderView.swift
import SwiftUI

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
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.accentMuted)
                        .frame(width: 44, height: 44)
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(briefKind) · \(timeRange) · \(stateLabel)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(stateColor)
                        .tracking(0.8)

                    // Headline now leads with the action-needed count, since that's
                    // the only number the user actually opens the app to learn.
                    Text(actionHeadline)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(highPriorityCount > 0 ? Theme.textPrimary : Theme.textSecondary)
                        .tracking(-0.5)

                    HStack(spacing: 5) {
                        Text("\(briefCount) brief\(briefCount == 1 ? "" : "s")")
                        Text("·")
                        Text("\(messageCount) message\(messageCount == 1 ? "" : "s")")
                        Text("·")
                        Text("\(peopleCount) \(peopleCount == 1 ? "person" : "people")")
                        if !failedServices.isEmpty {
                            Text("·")
                            Text("\(failedServices.count) failed")
                                .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.25))
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        chatViewModel.inputText = "What changed since the last brief?"
                        Task { await chatViewModel.send() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "clock.arrow.2.circlepath")
                                .font(.system(size: 11, weight: .bold))
                            Text("What changed ↗")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)

                    Button {
                        InstrumentationManager.shared.track(event: .refreshTriggered, metadata: ["source": "header"])
                        onRefresh?()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .bold))
                            Text("Refresh")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textPrimary)
                }
            }

            if !failedServices.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.25))
                    Text("Partial brief:")
                        .font(.system(size: 12, weight: .bold))
                    Text("Failed to reach \(failedServices.map { Theme.serviceName($0) }.joined(separator: ", ")).")
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(red: 0.95, green: 0.45, blue: 0.25).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(Theme.textPrimary)
            }

            if highPriorityCount > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.25))
                    
                    Text("\(highPriorityCount) items require your attention now")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(red: 0.95, green: 0.45, blue: 0.25).opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(red: 0.95, green: 0.45, blue: 0.25).opacity(0.2), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if let errorText, !errorText.isEmpty {
                Text(errorText)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.25))
                    .padding(.top, -4)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
    }

    private var headlineText: String {
        if briefCount == 0 && messageCount == 0 { return "No new messages" }
        if briefCount == 0 { return "\(messageCount) message\(messageCount == 1 ? "" : "s")" }
        return "\(briefCount) brief\(briefCount == 1 ? "" : "s") across \(serviceCount) app\(serviceCount == 1 ? "" : "s")"
    }

    /// What the user came here to learn, in priority order:
    ///   • some action needed → "1 action needed"
    ///   • no actions but some content → "Nothing urgent · 1 brief"
    ///   • empty brief → "No new messages"
    private var actionHeadline: String {
        if briefCount == 0 && messageCount == 0 { return "No new messages" }
        if highPriorityCount > 0 {
            return "\(highPriorityCount) action\(highPriorityCount == 1 ? "" : "s") needed"
        }
        if briefCount > 0 {
            return "Nothing urgent · \(briefCount) brief\(briefCount == 1 ? "" : "s")"
        }
        return "\(messageCount) new message\(messageCount == 1 ? "" : "s")"
    }

    private var briefKind: String {
        guard let start = brief.windowStart else { return "HOURLY BRIEF" }
        let hours = Int(brief.createdAt.timeIntervalSince(start) / 3600)
        if hours >= 24 * 6 { return "7-DAY BRIEF" }
        if hours >= 24 { return "\(hours / 24)D BRIEF" }
        if hours >= 2  { return "\(hours)H BRIEF" }
        return "HOURLY BRIEF"
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

    private var stateLabel: String {
        switch generationState {
        case .cached: return ""
        case .fetching: return "FETCHING"
        case .summarizing: return "UPDATING"
        case .partial: return "Partially updated"
        case .complete: return "READY"
        case .noNewMessages: return "NO NEW MESSAGES"
        case .failed: return "FAILED"
        }
    }

    private var stateColor: Color {
        switch generationState {
        case .complete, .cached, .noNewMessages:
            return Theme.textTertiary
        case .fetching, .summarizing:
            return Theme.accent
        case .partial:
            return Color(red: 0.90, green: 0.72, blue: 0.30)
        case .failed:
            return Color(red: 0.95, green: 0.45, blue: 0.25)
        }
    }
}
