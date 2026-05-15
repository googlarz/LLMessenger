import SwiftUI

struct SlackWorkspacesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var workspaces: [SlackWorkspace] = SlackWorkspaceStore.load()
    @State private var showingAdd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Slack Workspaces")
                    .font(.title3).bold()
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Divider()

            if workspaces.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "number.square")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No workspaces yet")
                        .font(.headline)
                    Text("Create a Slack app at api.slack.com/apps, add the required OAuth scopes, install it to your workspace, then paste the User OAuth Token here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                                remove(ws)
                            }
                            Divider()
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                Link("Required scopes & setup guide →",
                     destination: URL(string: "https://api.slack.com/apps")!)
                    .font(.caption)
                Spacer()
                Button {
                    showingAdd = true
                } label: {
                    Label("Add workspace", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 520, height: 420)
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

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.55, green: 0.36, blue: 0.66))
                    .frame(width: 30, height: 30)
                Text(workspace.teamName.prefix(1).uppercased())
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.teamName)
                    .font(.system(size: 13, weight: .semibold))
                Text("Signed in as \(workspace.userName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove workspace")
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
                .font(.title3).bold()

            Text("Paste the User OAuth Token (starts with `xoxp-`) from your Slack app's OAuth & Permissions page. We'll validate the token via auth.test before saving.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("xoxp-…", text: $token)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Link("Open api.slack.com/apps →", destination: URL(string: "https://api.slack.com/apps")!)
                    .font(.caption)
                Spacer()
                Button("Cancel") { dismiss() }
                Button {
                    Task { await validateAndSave() }
                } label: {
                    HStack(spacing: 6) {
                        if isValidating { ProgressView().controlSize(.small) }
                        Text("Add")
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || isValidating)
            }
        }
        .padding(22)
        .frame(width: 480)
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
