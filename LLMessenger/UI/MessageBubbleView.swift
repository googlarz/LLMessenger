// LLMessenger/UI/MessageBubbleView.swift
import SwiftUI

struct MessageBubbleView: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(message.sender)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                    Text(message.timestamp, style: .time)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(message.text)
                    .font(.body)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
