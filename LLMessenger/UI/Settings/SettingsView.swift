// LLMessenger/UI/Settings/SettingsView.swift
import SwiftUI

enum SettingsPane: Int, CaseIterable, Identifiable {
    case aiPrivacy
    case services
    case behavior
    case schedule
    case about

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .aiPrivacy: return "AI & Privacy"
        case .services: return "Services"
        case .behavior: return "Behavior"
        case .schedule: return "Schedule"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .aiPrivacy: return "sparkles"
        case .services: return "point.3.connected.trianglepath.dotted"
        case .behavior: return "slider.horizontal.3"
        case .schedule: return "clock"
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
        pane = SettingsPane(rawValue: defaults.integer(forKey: Self.defaultsKey)) ?? .aiPrivacy
    }
}

struct SettingsView: View {
    var database: AppDatabase? = nil
    var onRunSetup: (() -> Void)? = nil
    var onBuild7DaySummaries: (() async -> Void)? = nil
    var onSyncContacts: (() async -> Void)? = nil
    var onRetryService: ((String) async -> Void)? = nil
    var onScheduleChanged: (() -> Void)? = nil
    var unsavedGuard: SettingsUnsavedGuard? = nil
    @ObservedObject var selection: SettingsPaneSelection
    // Owned here, not inside SubTabbedPane: tabContent below is `.id(selection.pane)`,
    // so navigating to another pane and back recreates SubTabbedPane from scratch —
    // if it owned this as local @State, the sub-tab (e.g. "Priority Rules") would
    // silently reset to the first tab ("Instructions") every time, even though the
    // top-level pane itself is remembered.
    @State private var aiPrivacySubTab = 0
    @State private var behaviorSubTab = 0
    // Form state lives here for the same reason: the pane and sub-tab views below are
    // recreated on every switch, so anything typed but not yet saved would be lost if the
    // views owned it. Each model shows an "Unsaved changes" bar until the user decides.
    @StateObject private var servicesModel: ServiceSettingsModel
    @StateObject private var aiModel = AISettingsModel()
    @StateObject private var instructionsModel = InstructionsSettingsModel()

    init(database: AppDatabase? = nil,
         onRunSetup: (() -> Void)? = nil,
         onBuild7DaySummaries: (() async -> Void)? = nil,
         onSyncContacts: (() async -> Void)? = nil,
         onRetryService: ((String) async -> Void)? = nil,
         onScheduleChanged: (() -> Void)? = nil,
         unsavedGuard: SettingsUnsavedGuard? = nil,
         selection: SettingsPaneSelection) {
        self.database = database
        self.onRunSetup = onRunSetup
        self.onBuild7DaySummaries = onBuild7DaySummaries
        self.onSyncContacts = onSyncContacts
        self.onRetryService = onRetryService
        self.onScheduleChanged = onScheduleChanged
        self.unsavedGuard = unsavedGuard
        self.selection = selection
        _servicesModel = StateObject(wrappedValue: ServiceSettingsModel(repo: SettingsRepository(database: database)))
    }

    var body: some View {
        tabContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            .id(selection.pane)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 560)
        .background(Theme.bg)
        .onAppear {
            guard let unsavedGuard else { return }
            let services = servicesModel, ai = aiModel, instructions = instructionsModel
            unsavedGuard.hasUnsaved = { services.hasUnsavedCredentials || ai.isDirty || instructions.isDirty }
            unsavedGuard.saveAll = {
                if services.hasUnsavedCredentials { services.saveCredentials() }
                if ai.isDirty { ai.save() }
                if instructions.isDirty { instructions.save() }
            }
            unsavedGuard.discardAll = {
                services.discardCredentials()
                ai.discard()
                instructions.discard()
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selection.pane {
        case .aiPrivacy:
            SubTabbedPane(tabs: ["AI", "Privacy"], sub: $aiPrivacySubTab) { sub in
                if sub == 0 {
                    AISettingsTab(database: database, model: aiModel)
                } else {
                    PrivacySettingsTab()
                }
            }
        case .services:
            ServiceSettingsTab(model: servicesModel,
                               onBuild7DaySummaries: onBuild7DaySummaries,
                               onSyncContacts: onSyncContacts,
                               onRetryService: onRetryService)
        case .behavior:
            SubTabbedPane(tabs: ["Writing & Appearance", "Priority Rules"], sub: $behaviorSubTab) { sub in
                if sub == 0 {
                    InstructionsSettingsTab(model: instructionsModel)
                } else {
                    RulesSettingsTab(database: database)
                }
            }
        case .schedule:
            DigestSettingsTab(onScheduleChanged: onScheduleChanged)
        case .about:
            AboutSettingsTab(database: database, onRunSetup: onRunSetup)
        }
    }
}

/// A pane hosting two closely-related settings surfaces behind a segmented
/// control, so the window keeps five top-level panes without discarding any
/// existing settings UI.
private struct SubTabbedPane<Content: View>: View {
    let tabs: [String]
    @Binding var sub: Int
    @ViewBuilder let content: (Int) -> Content

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $sub) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { idx, title in
                    Text(title).tag(idx)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            .padding(.top, 12)
            .padding(.bottom, 6)
            content(sub)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(sub)
        }
    }
}
