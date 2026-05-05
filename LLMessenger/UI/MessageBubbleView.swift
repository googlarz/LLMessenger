// LLMessenger/UI/MessageBubbleView.swift
import SwiftUI

struct MessageBubbleView: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Avatar
            ZStack {
                Circle()
                    .fill(avatarColor)
                    .frame(width: 28, height: 28)
                Text(String(message.sender.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text(message.timestamp, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                    Text(message.service.capitalized)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Theme.border, lineWidth: 0.5)
                        )
                }
                Text(message.text)
                    .font(.system(size: 13))
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

    private var avatarColor: Color {
        let palette: [Color] = [
            Color(red: 0.35, green: 0.55, blue: 0.75),
            Color(red: 0.55, green: 0.45, blue: 0.75),
            Color(red: 0.75, green: 0.45, blue: 0.45),
            Color(red: 0.40, green: 0.65, blue: 0.55),
            Color(red: 0.65, green: 0.55, blue: 0.35),
        ]
        return palette[abs(message.sender.hashValue) % palette.count]
    }
}
