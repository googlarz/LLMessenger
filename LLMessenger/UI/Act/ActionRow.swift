// LLMessenger/UI/Act/ActionRow.swift
//
// One proposed action in the Act queue. Shows the kind badge, service, who it's
// for, the drafted text (editable inline), the reasoning, and Approve/Edit/Skip.

import AppKit
import SwiftUI

struct ActionRow: View {
    @EnvironmentObject var appState: AppState
    let action: AgentAction

    @State private var isEditing = false
    @State private var editText = ""
    @State private var isHovered = false
    @State private var showContextEditor = false

    private var draftText: String {
        action.replyPayload?.draftText ?? action.payload
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                kindBadge
                ServiceStamp(service: action.service, size: 18)

                Text(action.conversationName.uppercased())
                    .font(Theme.mono(11, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)

                Spacer()

                WireLabel(action.riskLevel, color: riskColor)
            }

            Text(action.title)
                .font(Theme.mono(10.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            if isEditing {
                TextEditor(text: $editText)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minHeight: 60)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.controlRadius)
                            .fill(Theme.surfaceHigh)
                    )
            } else {
                Text(draftText)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !action.reasoning.isEmpty {
                Text(action.reasoning)
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if action.statusEnum == .scheduled {
                    armedBar
                } else if isEditing {
                    actionButton("SAVE") {
                        appState.editAction(action, newText: editText)
                        isEditing = false
                    }
                    actionButton("CANCEL") { isEditing = false }
                } else {
                    actionButton("APPROVE") {
                        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                        appState.approveAction(action)
                    }
                    actionButton("EDIT") {
                        editText = draftText
                        isEditing = true
                    }
                    actionButton("SKIP") {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                        appState.skipAction(action)
                    }
                }
                Spacer()
                Button("Customize lane") { showContextEditor = true }
                    .buttonStyle(WireActionStyle())
                    .accessibilityLabel("Customize delegation settings for \(action.conversationName)")
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 12)
        .sheet(isPresented: $showContextEditor) {
            ContextEditor(
                service: action.service,
                conversationId: action.conversationId,
                conversationName: action.conversationName,
                database: appState.database
            )
        }
        .background(isHovered ? Theme.surface.opacity(0.5) : Color.clear)
        .animation(Theme.quick, value: isHovered)
        .onHover { isHovered = $0 }
    }

    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var armedBar: some View {
        HStack(spacing: 8) {
            Text("SENDING IN \(secondsRemaining)s")
                .font(Theme.mono(11, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(Theme.signal)
            actionButton("UNDO") { appState.undoAutoSend(action) }
        }
        .onReceive(ticker) { now = $0 }
    }

    private var secondsRemaining: Int {
        guard let fireAt = action.scheduledAt else { return 0 }
        return max(0, Int(fireAt.timeIntervalSince(now).rounded(.up)))
    }

    private var kindBadge: some View {
        WireLabel(badgeText, color: Theme.textTertiary)
    }

    private var badgeText: String {
        switch action.kindEnum {
        case .reply:        return "Reply"
        case .followUp:     return "Follow up"
        case .calendarHold: return "Hold"
        case .rsvp:         return "RSVP"
        case .ack:          return "Ack"
        case .none:         return action.kind
        }
    }

    private var riskColor: Color {
        switch action.riskEnum {
        case .high:   return Theme.signal
        case .normal: return Theme.standby
        case .low:    return Theme.textTertiary
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(WireActionStyle())
    }
}
