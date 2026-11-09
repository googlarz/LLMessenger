// LLMessenger/UI/LoadingIndicatorView.swift
import SwiftUI

struct LoadingIndicatorView: View {
    @State private var phase = 0

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Theme.textSecondary.opacity(0.5)
                .frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))
                .padding(.vertical, 2)

            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Theme.textTertiary)
                        .frame(width: 4, height: 4)
                        .opacity(phase == i ? 1.0 : 0.3)
                        .scaleEffect(phase == i ? 1.2 : 1.0)
                        .animation(Theme.quick, value: phase)
                }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 380_000_000)
                    phase = (phase + 1) % 3
                }
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 10)
    }
}
