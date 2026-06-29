// LLMessenger/UI/Settings/DigestSettingsTab.swift
import SwiftUI

struct DigestSettingsTab: View {
    var onScheduleChanged: (() -> Void)? = nil

    @State private var settings: DigestScheduler.Settings = {
        SettingsRepository().loadDigestSettings()
    }()
    @State private var firewallEnabled: Bool = SettingsRepository().loadFirewallEnabled()
    @State private var heldBackCount: Int = SettingsRepository().loadFirewallHeldBack()

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
                            .onChange(of: settings.enabled) { _ in save() }
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
                                        .onChange(of: settings.hour) { _ in save() }
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
                                    .onChange(of: settings.minute) { _ in save() }
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
                            .onChange(of: firewallEnabled) { enabled in
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

                // MARK: - Notes
                VStack(alignment: .leading, spacing: 8) {
                    WireLabel("Requirements")
                    Text("The app must be running at the scheduled time. Enable \"Launch at Login\" in macOS System Settings → General → Login Items to ensure the digest fires reliably.")
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(3)
                    Button("Open Login Items") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(WireActionStyle())
                    .padding(.top, 2)
                }
                .padding(20)
            }
        }
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
