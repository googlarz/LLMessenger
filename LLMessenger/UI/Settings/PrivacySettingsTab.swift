import SwiftUI

struct PrivacySettingsTab: View {
    @State private var localOnlyMode: Bool = SettingsRepository().loadLocalOnlyMode()
    @State private var sanitizeBeforeSend: Bool = SettingsRepository().loadSanitizeBeforeSend()
    @ObservedObject private var auditLog = NetworkAuditLog.shared
    private let repo = SettingsRepository()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                modesSection
                Rule()
                dataFlowSection
                Rule()
                networkLogSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Modes

    private var modesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            WireLabel("Privacy")

            Toggle(isOn: $localOnlyMode) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Local-only mode")
                        .font(Theme.sans(13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Forces Ollama as the LLM and stops cloud-only adapters such as Slack immediately. Existing in-flight requests may finish, but new cloud message processing is blocked.")
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.ok)
            .onChange(of: localOnlyMode) {
                repo.saveLocalOnlyMode($0)
                NotificationCenter.default.post(name: .privacyModeDidChange, object: nil)
                NotificationCenter.default.post(name: .llmProviderDidChange, object: nil)
            }

            Rule()

            Toggle(isOn: $sanitizeBeforeSend) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Redact sensitive patterns before sending to cloud LLM")
                        .font(Theme.sans(13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Replaces credit card numbers, US SSNs, IBANs, and email addresses with [REDACTED:…] tokens in cloud LLM prompts. Best-effort, not a guarantee. May reduce digest quality.")
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.ok)
            .onChange(of: sanitizeBeforeSend) { repo.saveSanitizeBeforeSend($0) }
        }
        .padding(.vertical, 14)
    }

    // MARK: - Data flow

    private var dataFlowSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            WireLabel("Data Flow")

            bullet("Your messages are stored locally at ~/Library/Application Support/LLMessenger/.")
            bullet("There is no LLMessenger server. The developer cannot see your data.")
            bullet("Cloud egress only happens when you configure Anthropic, OpenAI, or Slack.")
            bullet("API keys and Slack tokens are stored in the macOS Keychain, never in plain files.")
            bullet("No analytics, telemetry, or auto-update beacon. The app does not call home.")

            Link("Read the full privacy & data-flow document →",
                 destination: URL(string: "https://github.com/googlarz/LLMessenger/blob/main/PRIVACY.md")!)
                .font(Theme.sans(11, weight: .medium))
                .tint(Theme.textSecondary)
                .padding(.top, 4)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Live network log

    private var networkLogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                WireLabel("Network Log — This Session")
                Spacer()
                Button("Clear") { auditLog.clear() }
                    .buttonStyle(WireActionStyle())
                    .disabled(auditLog.entries.isEmpty)
            }

            if auditLog.entries.isEmpty {
                Text("No outbound requests recorded yet. The app records every cloud HTTPS call here — only metadata (provider, endpoint, status, byte count), never message content.")
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(auditLog.entries.reversed()) { entry in
                        AuditRow(entry: entry)
                        if entry.id != auditLog.entries.reversed().last?.id {
                            Rule()
                        }
                    }
                }
            }
        }
        .padding(.vertical, 14)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(Theme.sans(12))
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
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 60, alignment: .leading)
            Text(entry.provider)
                .font(Theme.sans(11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 90, alignment: .leading)
            Text("\(entry.method) \(entry.endpoint)")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(rightLabel)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.vertical, 6)
    }

    private var statusColor: Color {
        if entry.isLocal { return Theme.textTertiary }
        if let s = entry.status, s < 400 { return Theme.ok }
        if entry.status != nil { return Theme.standby }
        return Theme.signal
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
