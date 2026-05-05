// LLMessenger/UI/AssistantResponseView.swift
import SwiftUI

struct AssistantResponseView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Anthropic-style accent bar
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 2)
                .cornerRadius(1)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("LLMessenger")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 32)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.accentMuted)
    }
}
