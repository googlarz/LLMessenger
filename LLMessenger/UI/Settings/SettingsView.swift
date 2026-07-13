// LLMessenger/UI/Settings/SettingsView.swift
import SwiftUI

enum SettingsPane: Int, CaseIterable, Identifiable {
    case ai
    case services
    case privacy
    case instructions
    case rules
    case digest
    case about

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .ai: return "AI"
        case .services: return "Services"
        case .privacy: return "Privacy"
        case .instructions: return "Instructions"
        case .rules: return "Rules"
        case .digest: return "Digest"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .ai: return "sparkles"
        case .services: return "point.3.connected.trianglepath.dotted"
        case .privacy: return "lock.shield"
        case .instructions: return "text.alignleft"
        case .rules: return "list.bullet.rectangle"
        case .digest: return "clock"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsPaneSelection: ObservableObject {
    private static let defaultsKey = "settings.selectedPane"

    @Published var pane: SettingsPane {
        didSet { UserDefaults.standard.set(pane.rawValue, forKey: Self.defaultsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        pane = SettingsPane(rawValue: defaults.integer(forKey: Self.defaultsKey)) ?? .ai
    }
}

struct SettingsView: View {
    var database: AppDatabase? = nil
    var onRunSetup: (() -> Void)? = nil
    var onBuild7DaySummaries: (() async -> Void)? = nil
    var onSyncContacts: (() async -> Void)? = nil
    var onRetryService: ((String) async -> Void)? = nil
    var onScheduleChanged: (() -> Void)? = nil
    @ObservedObject var selection: SettingsPaneSelection

    var body: some View {
        tabContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            .id(selection.pane)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 560)
        .background(Theme.bg)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selection.pane {
        case .ai:
            AISettingsTab(database: database)
        case .services:
            ServiceSettingsTab(database: database,
                               onBuild7DaySummaries: onBuild7DaySummaries,
                               onSyncContacts: onSyncContacts,
                               onRetryService: onRetryService)
        case .privacy:
            PrivacySettingsTab()
        case .instructions:
            InstructionsSettingsTab()
        case .rules:
            RulesSettingsTab(database: database)
        case .digest:
            DigestSettingsTab(onScheduleChanged: onScheduleChanged)
        case .about:
            AboutSettingsTab(database: database, onRunSetup: onRunSetup)
        }
    }
}
