import SwiftUI

struct SlackWorkspacesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var workspaces: [SlackWorkspace] = SlackWorkspaceStore.load()
    @State private var showingAdd = false
    @State private var workspaceToRemove: SlackWorkspace? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Slack Workspaces")
                    .font(Theme.display(17))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(PaperButtonStyle())
                    .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Rule()

            if workspaces.isEmpty {
                VStack(spacing: 10) {
                    WireLabel("Slack")
                    Text("No workspaces yet.")
                        .font(Theme.display(16.5))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Create a Slack app at api.slack.com/apps, add the required OAuth scopes, install it to your workspace, then paste the User OAuth Token here.")
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(workspaces) { ws in
                            WorkspaceRow(workspace: ws) {
                                workspaceToRemove = ws
                            }
                            Rule()
                        }
                    }
                }
            }

            Rule()

            HStack(spacing: 10) {
                Link("Required scopes & setup guide →",
                     destination: URL(string: "https://api.slack.com/apps")!)
                    .font(Theme.sans(11))
                    .tint(Theme.textSecondary)
                Spacer()
                Button("Add workspace") {
                    showingAdd = true
                }
                .buttonStyle(PaperButtonStyle(prominent: true))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 520, height: 420)
        .background(Theme.surface)
        .confirmationDialog(
            workspaceToRemove.map { "Remove \($0.teamName)?" } ?? "Remove workspace?",
            isPresented: Binding(
                get: { workspaceToRemove != nil },
                set: { if !$0 { workspaceToRemove = nil } }
            ), titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let ws = workspaceToRemove { remove(ws) }
                workspaceToRemove = nil
            }
            Button("Cancel", role: .cancel) { workspaceToRemove = nil }
        }
        .sheet(isPresented: $showingAdd, onDismiss: { reload() }) {
            AddSlackWorkspaceView()
        }
    }

    private func reload() {
        workspaces = SlackWorkspaceStore.load()
    }

    private func remove(_ ws: SlackWorkspace) {
        if let updated = try? SlackWorkspaceStore.remove(teamId: ws.teamId) {
            workspaces = updated
        }
    }
}

private struct WorkspaceRow: View {
    let workspace: SlackWorkspace
    let onRemove: () -> Void
    @State private var removeHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Stamp-style team initial — muted service ink, never the brand fill.
            Text(workspace.teamName.prefix(1).uppercased())
                .font(Theme.mono(11, weight: .bold))
                .foregroundStyle(Theme.serviceSlack)
                .frame(width: 26, height: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Theme.serviceSlack.opacity(0.55), lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.teamName)
                    .font(Theme.sans(13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Signed in as \(workspace.userName)")
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(removeHovered ? Theme.signal : Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Remove workspace")
            .animation(Theme.quick, value: removeHovered)
            .onHover { removeHovered = $0 }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

// MARK: - Add workspace sheet

private struct AddSlackWorkspaceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var token: String = ""
    @State private var isValidating = false
    @State private var error: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Slack Workspace")
                .font(Theme.display(16.5))
                .foregroundStyle(Theme.textPrimary)

            Text("Paste the User OAuth Token (starts with `xoxp-`) from your Slack app's OAuth & Permissions page. We'll validate the token via auth.test before saving.")
                .font(Theme.sans(11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("xoxp-…", text: $token)
                .textFieldStyle(.roundedBorder)
                .font(Theme.mono(12))

            if let error {
                Text(error)
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.signal)
            }

            HStack {
                Link("Open api.slack.com/apps →", destination: URL(string: "https://api.slack.com/apps")!)
                    .font(Theme.sans(11))
                    .tint(Theme.textSecondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(PaperButtonStyle())
                Button {
                    Task { await validateAndSave() }
                } label: {
                    HStack(spacing: 6) {
                        if isValidating { ProgressView().controlSize(.small) }
                        Text("Add")
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(PaperButtonStyle(prominent: true))
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || isValidating)
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(Theme.surface)
    }

    private func validateAndSave() async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("xoxp-") else {
            error = "Expected a User OAuth Token starting with xoxp-."
            return
        }
        isValidating = true
        error = nil
        defer { isValidating = false }

        // Stub a workspace just to call auth.test with the raw token.
        let stub = SlackWorkspace(teamId: "", teamName: "", token: trimmed, userId: "", userName: "")
        let client = SlackAPIClient(workspace: stub)
        do {
            let resp = try await client.authTest()
            guard resp.ok, let teamId = resp.team_id, let userId = resp.user_id else {
                error = "Slack rejected the token: \(resp.error ?? "unknown")"
                return
            }
            let ws = SlackWorkspace(
                teamId: teamId,
                teamName: resp.team ?? "Slack",
                token: trimmed,
                userId: userId,
                userName: resp.user ?? "you"
            )
            _ = try SlackWorkspaceStore.add(ws)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
