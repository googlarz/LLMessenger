import SwiftUI

struct PrivacySettingsTab: View {
    @State private var localOnlyMode: Bool = SettingsRepository().loadLocalOnlyMode()
    @State private var sanitizeBeforeSend: Bool = SettingsRepository().loadSanitizeBeforeSend()
    @ObservedObject private var auditLog = NetworkAuditLog.shared
    private let repo = SettingsRepository()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                modesSection
                dataFlowSection
                networkLogSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Modes

    private var modesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PRIVACY")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)

            VStack(alignment: .leading, spacing: 0) {
                Toggle(isOn: $localOnlyMode) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Local-only mode")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Forces Ollama as the LLM and skips the Slack adapter. With this on, no message content leaves your Mac. Requires app restart to take effect for adapter registration.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .padding(14)
                .onChange(of: localOnlyMode) { repo.saveLocalOnlyMode($0) }

                Divider().padding(.leading, 14)

                Toggle(isOn: $sanitizeBeforeSend) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Redact sensitive patterns before sending to cloud LLM")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Replaces credit card numbers, US SSNs, IBANs, and email addresses with [REDACTED:…] tokens in cloud LLM prompts. Best-effort, not a guarantee. May reduce brief quality.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .padding(14)
                .onChange(of: sanitizeBeforeSend) { repo.saveSanitizeBeforeSend($0) }
            }
            .background(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Data flow

    private var dataFlowSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DATA FLOW")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)

            VStack(alignment: .leading, spacing: 8) {
                bullet("Your messages are stored locally at ~/Library/Application Support/LLMessenger/.")
                bullet("There is no LLMessenger server. The developer cannot see your data.")
                bullet("Cloud egress only happens when you configure Anthropic, OpenAI, or Slack.")
                bullet("API keys and Slack tokens are stored in the macOS Keychain, never in plain files.")
                bullet("No analytics, telemetry, or auto-update beacon. The app does not call home.")

                Link("Read the full privacy & data-flow document →",
                     destination: URL(string: "https://github.com/googlarz/LLMessenger/blob/main/PRIVACY.md")!)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.top, 4)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Live network log

    private var networkLogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("NETWORK LOG (THIS SESSION)")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Clear") { auditLog.clear() }
                    .controlSize(.small)
                    .disabled(auditLog.entries.isEmpty)
            }

            if auditLog.entries.isEmpty {
                Text("No outbound requests recorded yet. The app records every cloud HTTPS call here — only metadata (provider, endpoint, status, byte count), never message content.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 0) {
                    ForEach(auditLog.entries.reversed()) { entry in
                        AuditRow(entry: entry)
                        if entry.id != auditLog.entries.reversed().last?.id {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .background(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}

private struct AuditRow: View {
    let entry: NetworkAuditLog.Entry
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 60, alignment: .leading)
            Text(entry.provider)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 90, alignment: .leading)
            Text("\(entry.method) \(entry.endpoint)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(rightLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var statusColor: Color {
        if entry.isLocal { return Theme.textTertiary }
        if let s = entry.status, s < 400 { return .green }
        if entry.status != nil { return .orange }
        return .red
    }

    private var rightLabel: String {
        var parts: [String] = []
        if let s = entry.status { parts.append("\(s)") }
        if entry.requestBytes > 0 { parts.append("\(entry.requestBytes) B") }
        if let ms = entry.durationMs { parts.append("\(ms) ms") }
        if entry.error != nil { parts.append("error") }
        return parts.joined(separator: " · ")
    }
}
