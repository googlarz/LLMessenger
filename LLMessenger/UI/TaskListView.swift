// LLMessenger/UI/TaskListView.swift
import SwiftUI

struct TaskListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text("TASKS (\(appState.tasks.count))")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .tracking(0.7)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if appState.tasks.isEmpty {
                Text("No pending tasks — action items from briefs appear here")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            } else {
                ForEach(appState.tasks, id: \.id) { task in
                    TaskRowView(task: task) {
                        if let id = task.id { appState.completeTask(id) }
                    }
                }
            }

            Divider()
                .background(Theme.border.opacity(0.5))
                .padding(.top, 4)
        }
    }
}

// MARK: - Task row

private struct TaskRowView: View {
    let task: BriefTask
    let onComplete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { onComplete() } label: {
                Image(systemName: "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(briefDateLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var briefDateLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(task.createdAt)     { return "Brief from today" }
        if cal.isDateInYesterday(task.createdAt) { return "Brief from yesterday" }
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return "Brief from \(f.string(from: task.createdAt))"
    }
}
