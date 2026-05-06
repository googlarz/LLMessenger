// LLMessenger/UI/AssistantResponseView.swift
import SwiftUI

// MARK: - Conversation picker (service disambiguation)

struct ConversationPickerView: View {
    let pickerID: UUID
    let originalRequest: String
    let options: [ConversationOption]

    @EnvironmentObject var chatViewModel: ChatViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 2)
                .cornerRadius(1)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("Which service?")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(options) { opt in
                        Button {
                            Task {
                                await chatViewModel.selectPickerOption(
                                    pickerID: pickerID,
                                    originalRequest: originalRequest,
                                    option: opt
                                )
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Text("\(opt.number)")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(Theme.accent)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                SourceGlyphView(service: opt.service, size: 18)
                                Text(Theme.serviceName(opt.service))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                if !opt.displayName.isEmpty && opt.displayName != opt.convId {
                                    Text("·").foregroundStyle(Theme.textTertiary)
                                    Text(opt.displayName)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Theme.surfaceHigh)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Or type a number and press ↵")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.accentMuted)
    }
}

struct UserMessageView: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.surfaceHigh)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

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
