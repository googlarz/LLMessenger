// LLMessenger/UI/Settings/DigestSettingsTab.swift
import SwiftUI

struct DigestSettingsTab: View {
    var onScheduleChanged: (() -> Void)? = nil

    @State private var settings: DigestScheduler.Settings = {
        SettingsRepository().loadDigestSettings()
    }()
    @State private var firewallEnabled: Bool = SettingsRepository().loadFirewallEnabled()
    @State private var heldBackCount: Int = SettingsRepository().loadFirewallHeldBack()
    @StateObject private var launchAtLogin = LaunchAtLoginModel()

    private let settingsRepo = SettingsRepository()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // MARK: - Morning Digest section
                VStack(alignment: .leading, spacing: 14) {
                    WireLabel("Morning Digest")

                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Daily digest")
                                .font(Theme.sans(13, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Generate a digest at a scheduled time and deliver a notification.")
                                .font(Theme.sans(11))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Toggle("", isOn: $settings.enabled)
                            .labelsHidden()
                            .accessibilityLabel("Schedule morning digest")
                            .toggleStyle(.switch)
                            .onChange(of: settings.enabled) { _, _ in save() }
                    }

                    if settings.enabled {
                        Rule()

                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 4) {
                                WireLabel("Hour")
                                HStack(spacing: 6) {
                                    Text(String(format: "%02d", settings.hour))
                                        .font(Theme.mono(20))
                                        .foregroundStyle(Theme.textPrimary)
                                        .frame(width: 40)
                                    Stepper("", value: $settings.hour, in: 0...23)
                                        .labelsHidden()
                                        .onChange(of: settings.hour) { _, _ in save() }
                                }
                            }

                            Text(":")
                                .font(Theme.mono(20))
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.top, 18)

                            VStack(alignment: .leading, spacing: 4) {
                                WireLabel("Minute")
                                HStack(spacing: 6) {
                                    Text(String(format: "%02d", settings.minute))
                                        .font(Theme.mono(20))
                                        .foregroundStyle(Theme.textPrimary)
                                        .frame(width: 40)
                                    Stepper("", value: Binding(
                                        get: { settings.minute },
                                        set: { settings.minute = ($0 / 15) * 15 }
                                    ), in: 0...59, step: 15)
                                    .labelsHidden()
                                    .onChange(of: settings.minute) { _, _ in save() }
                                }
                            }

                            Spacer()
                        }

                        Rule()

                        if let next = DigestScheduler().nextFireDate(for: settings) {
                            HStack(spacing: 6) {
                                WireLabel("Next digest:")
                                Text(nextLabel(for: next))
                                    .font(Theme.mono(11))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                .padding(20)

                Rule()

                // MARK: - Notification Firewall section
                VStack(alignment: .leading, spacing: 14) {
                    WireLabel("Notification Firewall")

                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Only interrupt for what matters")
                                .font(Theme.sans(13, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Routine digests are generated silently — you're only notified when something needs your reply. Everything held back appears in the next digest.")
                                .font(Theme.sans(11))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Toggle("", isOn: $firewallEnabled)
                            .labelsHidden()
                            .accessibilityLabel("Only interrupt for what matters")
                            .toggleStyle(.switch)
                            .onChange(of: firewallEnabled) { _, enabled in
                                settingsRepo.saveFirewallEnabled(enabled)
                            }
                    }

                    if firewallEnabled, heldBackCount > 0 {
                        HStack(spacing: 6) {
                            WireLabel("Held back:")
                            Text("\(heldBackCount) routine update\(heldBackCount == 1 ? "" : "s") since the last digest")
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .padding(20)

                Rule()

                // MARK: - Launch at login
                VStack(alignment: .leading, spacing: 14) {
                    WireLabel("Launch at Login")

                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Open LLMessenger when you log in")
                                .font(Theme.sans(13, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Digests only run while LLMessenger is open. Starting it at login keeps the schedule above reliable.")
                                .font(Theme.sans(11))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { launchAtLogin.isOn },
                                                 set: { launchAtLogin.set($0) }))
                            .labelsHidden()
                            .accessibilityLabel("Open LLMessenger at login")
                            .toggleStyle(.switch)
                    }

                    if let error = launchAtLogin.errorMessage {
                        Text(error)
                            .font(Theme.sans(11))
                            .foregroundStyle(Theme.signal)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if launchAtLogin.needsApproval {
                        Text("macOS is waiting for your approval. Allow LLMessenger in System Settings → General → Login Items.")
                            .font(Theme.sans(11))
                            .foregroundStyle(Theme.standby)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button("Open Login Items") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(WireActionStyle())
                }
                .padding(20)
            }
        }
        .onAppear { launchAtLogin.refresh() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private func save() {
        settingsRepo.saveDigestSettings(settings)
        onScheduleChanged?()
    }

    private func nextLabel(for date: Date) -> String {
        let cal = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let timeStr = formatter.string(from: date)
        if cal.isDateInToday(date) { return "Today at \(timeStr)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow at \(timeStr)" }
        return timeStr
    }
}
