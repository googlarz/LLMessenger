// LLMessenger/UI/AssistantResponseView.swift
import SwiftUI

struct AssistantResponseView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "cpu.fill")
                .foregroundStyle(.blue)
                .font(.caption)
                .padding(.top, 3)

            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)

            Spacer(minLength: 40)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.blue.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
    }
}
