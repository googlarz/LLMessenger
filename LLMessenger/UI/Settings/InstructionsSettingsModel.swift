// LLMessenger/UI/Settings/InstructionsSettingsModel.swift
//
// State for Settings → Behavior → Writing & Appearance. Owned by SettingsView so unsaved
// edits survive switching tabs.
//
// - Theme applies and saves the moment it is chosen.
// - The system prompt and digest language wait for Save. The language is read for each
//   new digest; the system prompt is read when LLMessenger starts.

import AppKit
import Foundation

@MainActor
final class InstructionsSettingsModel: ObservableObject {
    struct Values: Equatable {
        var prompt = ""
        var briefLanguage = "English"
    }

    enum Status: Equatable {
        case idle
        case saved
    }

    @Published var values = Values()
    @Published private(set) var saved = Values()
    @Published private(set) var theme: String = "system"
    @Published private(set) var status: Status = .idle

    private let repo: SettingsRepository
    private let applyAppearance: @MainActor (String) -> Void
    private var clearTask: Task<Void, Never>?

    init(repo: SettingsRepository = SettingsRepository(),
         applyAppearance: @escaping @MainActor (String) -> Void = InstructionsSettingsModel.applyToApp) {
        self.repo = repo
        self.applyAppearance = applyAppearance
        load()
    }

    var isDirty: Bool { values != saved }

    func load() {
        theme = repo.loadTheme()
        guard !isDirty else { return }
        let storedPrompt = repo.loadBasePrompt()
        let loaded = Values(prompt: storedPrompt.isEmpty ? PromptBuilder.defaultBasePrompt : storedPrompt,
                            briefLanguage: repo.loadBriefLanguage())
        values = loaded
        saved = loaded
    }

    /// Saves and applies the theme immediately.
    func setTheme(_ newTheme: String) {
        guard newTheme != theme else { return }
        theme = newTheme
        repo.saveTheme(newTheme)
        applyAppearance(newTheme)
    }

    func resetPromptToDefault() {
        values.prompt = PromptBuilder.defaultBasePrompt
    }

    func save() {
        repo.saveBasePrompt(values.prompt)
        repo.saveBriefLanguage(values.briefLanguage)
        saved = values
        status = .saved
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.status = .idle
        }
    }

    func discard() {
        values = saved
        status = .idle
    }

    static func applyToApp(_ theme: String) {
        let appearance: NSAppearance? = switch theme {
        case "light": NSAppearance(named: .aqua)
        case "dark":  NSAppearance(named: .darkAqua)
        default:      nil
        }
        NSApp.appearance = appearance
    }
}

/// When each control on that tab takes effect, stated per control.
enum InstructionsCopy {
    static let promptTiming = "Added before every AI request. Takes effect the next time LLMessenger starts."
    static let languageTiming = "Digests are written in this language from the next one on, even when the messages are in another language. Drafts and chat answers aren't affected."
    static let themeTiming = "Applies as soon as you choose it."
}
