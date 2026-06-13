// LLMessenger/UI/Act/ActionRow.swift
//
// One proposed action in the Act queue. Shows the kind badge, service, who it's
// for, the drafted text (editable inline), the reasoning, and Approve/Edit/Skip.

import SwiftUI

struct ActionRow: View {
    @EnvironmentObject var appState: AppState
    let action: AgentAction

    @State private var isEditing = false
    @State private var editText = ""

    private var draftText: String {
        action.replyPayload?.draftText ?? action.payload
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                kindBadge
                ServiceStamp(service: action.service, size: 18)

                Text(action.conversationName.uppercased())
                    .font(Theme.mono(10, weight: .semibold))
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
                if isEditing {
                    actionButton("Save") {
                        appState.editAction(action, newText: editText)
                        isEditing = false
                    }
                    actionButton("Cancel") { isEditing = false }
                } else {
                    actionButton("Approve") { appState.approveAction(action) }
                    actionButton("Edit") {
                        editText = draftText
                        isEditing = true
                    }
                    actionButton("Skip") { appState.skipAction(action) }
                }
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 12)
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
        Button(action: action) {
            Text(title.uppercased())
                .font(Theme.mono(9.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: Theme.controlRadius)
                        .fill(Theme.surfaceHigh)
                )
        }
        .buttonStyle(.plain)
    }
}
