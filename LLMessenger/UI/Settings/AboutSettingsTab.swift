// LLMessenger/UI/Settings/AboutSettingsTab.swift
import SwiftUI

struct AboutSettingsTab: View {
    var database: AppDatabase? = nil
    var onRunSetup: (() -> Void)? = nil

    var body: some View {
        // Scrolls so nothing is ever cut off in a short window.
        ScrollView {
            VStack(spacing: 0) {
            VStack(spacing: 20) {
                // Masthead: serif wordmark over a mono version line — typeset, not badged.
                VStack(spacing: 6) {
                    Text("LLMessenger")
                        .font(Theme.display(26))
                        .foregroundStyle(Theme.textPrimary)
                    Text("v\(appVersion)")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textTertiary)
                }

                Rule().frame(maxWidth: 320)

                VStack(spacing: 8) {
                    Text("Made by Dawid Piaskowski")
                        .font(Theme.sans(13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)

                    Link("github.com/googlarz/LLMessenger",
                         destination: URL(string: "https://github.com/googlarz/LLMessenger")!)
                        .font(Theme.mono(11))
                        .tint(Theme.textSecondary)
                }

                Rule().frame(maxWidth: 320)

                Text("Released under the Apache 2.0 License\nFree to use, modify, and distribute")
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)

                HStack(spacing: 10) {
                    if let onRunSetup {
                        Button("Run Setup Wizard", action: onRunSetup)
                            .buttonStyle(PaperButtonStyle())
                    }
                    if let database {
                        Button("Export Diagnostics") {
                            DiagnosticsReporter.export(database: database)
                        }
                        .buttonStyle(PaperButtonStyle())
                        .help("Versions, store integrity, service health, crash reports — never message content")
                    }
                }

                if let database {
                    HStack(spacing: 10) {
                        Button("Export Backup") {
                            DataExporter.export(database: database)
                        }
                        .buttonStyle(PaperButtonStyle())
                        .help("Digest history, learned context, and preferences. Not credentials — you'll sign back in to each service.")

                        if let path = database.path {
                            Button("Restore Backup…") {
                                DataExporter.promptImport(currentDatabasePath: path)
                            }
                            .buttonStyle(PaperButtonStyle())
                            .help("Replaces your current data with a backup, then quits the app for the change to take effect.")
                        }
                    }
                }

                Rule().frame(maxWidth: 320)

                whatsNew
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    /// The newest release is always shown in full; older ones scroll beneath it.
    private var whatsNew: some View {
        VStack(alignment: .leading, spacing: 0) {
            WireLabel("What's new")
                .padding(.bottom, 8)

            if let newest = ReleaseNotes.all.first {
                releaseEntry(newest)
            }

            let older = Array(ReleaseNotes.all.dropFirst())
            if !older.isEmpty {
                Rule().padding(.vertical, 12)
                WireLabel("Earlier versions")
                    .padding(.bottom, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(older) { releaseEntry($0) }
                    }
                    .padding(.trailing, 8)
                }
                .frame(maxHeight: 140)
            }

            Link("Full release history →",
                 destination: URL(string: "https://github.com/googlarz/LLMessenger/releases")!)
                .font(Theme.mono(10.5))
                .tint(Theme.textTertiary)
                .padding(.top, 12)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What's new in recent versions")
    }

    private func releaseEntry(_ note: ReleaseNote) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("v\(note.version)")
                    .font(Theme.mono(10.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text(note.title)
                    .font(Theme.sans(12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
            }
            ForEach(note.highlights, id: \.self) { line in
                HStack(alignment: .top, spacing: 6) {
                    Text("·")
                        .font(Theme.sans(11.5))
                        .foregroundStyle(Theme.textTertiary)
                    Text(line)
                        .font(Theme.sans(11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
}
