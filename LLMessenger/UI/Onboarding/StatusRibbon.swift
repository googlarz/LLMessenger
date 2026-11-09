// LLMessenger/UI/Onboarding/StatusRibbon.swift
//
// A slim strip at the top of the main window for the three states in which the
// window is not showing the user's real, working data: sample data, unfinished
// setup, and no AI model chosen yet.
import SwiftUI

extension Notification.Name {
    /// Posted by the ribbon's "Finish setup"; AppDelegate reopens the wizard.
    static let resumeOnboardingRequested = Notification.Name("com.llmessenger.resumeOnboardingRequested")
}

/// Production-only signals. They default to false so tests, snapshots and the
/// UI-test fixture render the main window exactly as before.
@MainActor
final class SetupProgress: ObservableObject {
    static let shared = SetupProgress()
    @Published var setupUnfinished = false
    @Published var needsAIChoice = false
}

enum StatusRibbonKind: Equatable {
    case sampleData, setupUnfinished, needsAI

    /// Sample data always wins: it is the one state where the user could mistake
    /// fiction for their own messages.
    static func resolve(demoActive: Bool, setupUnfinished: Bool, needsAIChoice: Bool) -> StatusRibbonKind? {
        if demoActive { return .sampleData }
        if setupUnfinished { return .setupUnfinished }
        if needsAIChoice { return .needsAI }
        return nil
    }

    var message: String {
        switch self {
        case .sampleData:      return "Sample data \u{2014} these aren\u{2019}t your messages."
        case .setupUnfinished: return "Setup isn\u{2019}t finished."
        case .needsAI:         return "Digests are paused until you choose an AI model."
        }
    }

    var buttonTitle: String {
        switch self {
        case .sampleData:      return "Set up with my messages"
        case .setupUnfinished: return "Finish setup"
        case .needsAI:         return "Choose an AI model"
        }
    }
}

struct StatusRibbon: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var progress = SetupProgress.shared

    private var kind: StatusRibbonKind? {
        StatusRibbonKind.resolve(demoActive: DemoSeeder.isActive,
                                 setupUnfinished: progress.setupUnfinished,
                                 needsAIChoice: progress.needsAIChoice)
    }

    var body: some View {
        if let kind {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Theme.standby.frame(width: 2, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 1))
                    Text(kind.message)
                        .font(Theme.sans(12.5))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 12)
                    Button(kind.buttonTitle) { act(kind) }
                        .buttonStyle(PaperButtonStyle())
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 7)
                .background(Theme.sidebar)
                Rule()
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(kind.message)
        }
    }

    private func act(_ kind: StatusRibbonKind) {
        switch kind {
        case .sampleData:      appState.onExitDemo?()
        case .setupUnfinished: NotificationCenter.default.post(name: .resumeOnboardingRequested, object: nil)
        case .needsAI:         appState.onOpenSettings?()
        }
    }
}
