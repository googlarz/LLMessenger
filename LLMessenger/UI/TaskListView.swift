// LLMessenger/UI/TaskListView.swift
import SwiftUI

struct TaskListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                WireLabel("Open items")
                Spacer()
                Text("\(appState.tasks.count)")
                    .font(Theme.mono(11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if appState.tasks.isEmpty {
                Text("No pending tasks — action items from digests appear here")
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            } else {
                ForEach(appState.tasks, id: \.id) { task in
                    TaskRowView(task: task) {
                        if let id = task.id { appState.completeTask(id) }
                    }
                }
            }

            Rule()
                .padding(.top, 6)
        }
    }
}

// MARK: - Task row

private struct TaskRowView: View {
    let task: BriefTask
    let onComplete: () -> Void
    @State private var checkHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button { onComplete() } label: {
                Image(systemName: checkHovered ? "checkmark.circle" : "circle")
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(checkHovered ? Theme.textSecondary : Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .help("Mark done")
            .accessibilityLabel("Mark task complete")
            .animation(Theme.quick, value: checkHovered)
            .onHover { checkHovered = $0 }

            VStack(alignment: .leading, spacing: 2) {
                Text(task.text)
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(briefDateLabel.uppercased())
                    .font(Theme.mono(8.5))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    private var briefDateLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(task.createdAt)     { return "From today" }
        if cal.isDateInYesterday(task.createdAt) { return "From yesterday" }
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return "From \(f.string(from: task.createdAt))"
    }
}
