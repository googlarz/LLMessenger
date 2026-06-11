// LLMessenger/UI/MessageBubbleView.swift
import SwiftUI

struct MessageBubbleView: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Avatar — quiet ink monogram, not a saturated badge
            ZStack {
                Circle()
                    .fill(Theme.surface)
                    .overlay(Circle().strokeBorder(Theme.border, lineWidth: Theme.hairline))
                    .frame(width: 28, height: 28)
                Text(String(message.sender.prefix(1)).uppercased())
                    .font(Theme.mono(11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(Theme.sans(11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text(message.timestamp, style: .time)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textTertiary)
                    ServiceStamp(service: message.service, size: 16)
                }
                Text(message.text)
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 32)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var displayName: String {
        if message.sender.hasPrefix("+") && message.sender.count > 6 {
            return "…" + message.sender.suffix(4)
        }
        return message.sender
    }
}
