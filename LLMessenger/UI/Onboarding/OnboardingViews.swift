// LLMessenger/UI/Onboarding/OnboardingViews.swift
import SwiftUI

// MARK: - Root

struct OnboardingRootView: View {
    @ObservedObject var model: OnboardingModel
    @State private var backHovered = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Group {
                switch model.step {
                case .welcome:  WelcomeStep(model: model)
                case .services: ServicesStep(model: model)
                case .access:   AccessStep(model: model)
                case .ai:       AIStep(model: model)
                case .finish:   FinishStep(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 560, idealHeight: 660)
        .background(Theme.bg)
        .foregroundStyle(Theme.textPrimary)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in model.tick() }
    }

    private var canGoBack: Bool {
        switch model.step {
        case .welcome, .services: return false
        case .finish: return model.buildStartedAt == nil
        default: return true
        }
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            if canGoBack {
                Button { model.goBack() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").accessibilityHidden(true).font(.system(size: 10, weight: .semibold))
                        Text("Back").font(Theme.sans(12.5))
                    }
                    .foregroundStyle(backHovered ? Theme.textPrimary : Theme.textSecondary)
                }
                .buttonStyle(.quiet)
                .onHover { backHovered = $0 }
            }
            Spacer()
            if model.step != .welcome { dots }
        }
        .frame(height: 44)
        .padding(.horizontal, 28)
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(model.visibleSteps, id: \.rawValue) { s in
                Button { model.jump(to: s) } label: {
                    Circle()
                        .fill(model.step == s ? Theme.textPrimary : Theme.border)
                        .frame(width: 6, height: 6)
                        .frame(width: 14, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.quiet)
                .disabled(!model.canJump(to: s))
                .accessibilityLabel(Self.label(for: s))
                .accessibilityValue(model.step == s ? "Current step" : "")
            }
        }
    }

    private static func label(for step: OnboardingStep) -> String {
        switch step {
        case .welcome: return "Welcome"
        case .services: return "Services"
        case .access: return "Permission"
        case .ai: return "AI model"
        case .finish: return "First digest"
        }
    }
}

// MARK: - Shared pieces

/// Left-aligned editorial frame: kicker, serif title, one sentence, content,
/// and a pinned footer under a hairline rule.
private struct StepFrame<Content: View, Footer: View>: View {
    let kicker: String
    var kickerColor: Color = Theme.textTertiary
    let title: String
    var subtitle: String?
    let content: Content
    let footer: Footer

    init(kicker: String, kickerColor: Color = Theme.textTertiary, title: String, subtitle: String? = nil,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.kicker = kicker
        self.kickerColor = kickerColor
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WireLabel(kicker, color: kickerColor)
                    Text(title)
                        .font(Theme.display(27))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.sans(13.5))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    content.padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 44)
                .padding(.top, 10)
                .padding(.bottom, 20)
            }
            Rule()
            VStack(alignment: .leading, spacing: 10) { footer }
                .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                .padding(.horizontal, 44)
                .padding(.vertical, 18)
        }
    }
}

private struct WizardButton: View {
    let title: String
    var prominent = true
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.sans(13.5, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
        }
        .buttonStyle(PaperButtonStyle(prominent: prominent))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

private struct QuietLink: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .buttonStyle(WireActionStyle.textAction())
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Theme.sans(11.5))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StatusLine: View {
    enum Kind { case waiting, ok, working }
    let kind: Kind
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(kind == .ok ? Theme.ok : Theme.textTertiary)
                .frame(width: 7, height: 7)
                .opacity(kind == .ok ? 1 : (pulse ? 1 : 0.3))
            Text(text)
                .font(Theme.sans(13, weight: .medium))
                .foregroundStyle(kind == .ok ? Theme.ok : Theme.textSecondary)
        }
        .onAppear {
            guard !reduceMotion, kind != .ok else { return }
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// An editorial margin-rule callout: colour bar on the left, no box.
private struct MarginNote<Content: View>: View {
    var tint: Color = Theme.standby
    let content: Content
    init(tint: Color = Theme.standby, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            tint.frame(width: 2).clipShape(RoundedRectangle(cornerRadius: 1))
            VStack(alignment: .leading, spacing: 10) { content }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DarkTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.border, lineWidth: 1))
            .foregroundStyle(Theme.textPrimary)
            .font(Theme.sans(12.5))
    }
}

// MARK: - Welcome

struct WelcomeStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        StepFrame(kicker: "LLMessenger", title: "Your messages, read for you.",
                  subtitle: "LLMessenger reads your chats and writes one short digest of what needs you. It drafts replies, and you approve every one.") {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").accessibilityHidden(true).font(.system(size: 10)).foregroundStyle(Theme.ok)
                    Text("Nothing leaves this Mac unless you choose a cloud model.")
                        .font(Theme.sans(12.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                sampleDigest
            }
        } footer: {
            WizardButton(title: "See it with sample messages") { model.startDemo() }
            Caption("No permissions, no accounts. One click.")
            WizardButton(title: "Set up with my messages", prominent: false) { model.startSetup() }
            Caption("About 5 minutes. Needs one macOS permission.")
            if let error = model.demoError { Caption("Couldn\u{2019}t open the sample messages: \(error)") }
            Rule().padding(.vertical, 4)
            MenuBarLocationNote()
        }
    }
}

extension WelcomeStep {
    /// An illustration of the product, not data: what one digest entry looks like.
    fileprivate var sampleDigest: some View {
        VStack(alignment: .leading, spacing: 0) {
            WireLabel("A digest looks like this").padding(.bottom, 8)
            Rule()
            entry("Anna needs the revised cap table before Thursday.", "Needs you \u{00B7} Signal \u{00B7} 12 messages", urgent: true)
            Rule()
            entry("Dad confirmed Sunday lunch and asks if 1pm works.", "Reply \u{00B7} iMessage \u{00B7} 4 messages", urgent: false)
            Rule()
            entry("Sailing club chatter, nothing for you.", "Quiet \u{00B7} Telegram \u{00B7} 31 messages", urgent: false)
            Rule()
        }
    }

    private func entry(_ headline: String, _ meta: String, urgent: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            (urgent ? Theme.signal : Color.clear).frame(width: 2).clipShape(RoundedRectangle(cornerRadius: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(Theme.display(14.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Text(meta.uppercased()).font(Theme.mono(10)).tracking(0.6).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 9)
    }
}

// MARK: - Services

private struct ChoiceBox: View {
    let selected: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(selected ? Theme.textPrimary : Theme.border, lineWidth: 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(selected ? Theme.textPrimary : Color.clear))
            .overlay(Image(systemName: "checkmark").accessibilityHidden(true).font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.bg).opacity(selected ? 1 : 0))
            .frame(width: 16, height: 16)
    }
}

private struct ServicesStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        StepFrame(kicker: "Step 1", title: "What should it read first?",
                  subtitle: "Pick what you use. You can add the rest any time.") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(OnboardingService.inWizardServices) { service in
                    pickRow(service)
                    Rule()
                }
                WireLabel("Later, in Settings \u{2192} Services").padding(.top, 20).padding(.bottom, 6)
                ForEach(OnboardingService.laterServices) { service in
                    laterRow(service)
                    Rule()
                }
            }
        } footer: {
            WizardButton(title: "Continue", enabled: model.canContinueFromServices) { model.continueFromServices() }
            if !model.canContinueFromServices {
                Caption("Pick one to continue, or skip setup and add services later.")
            }
            QuietLink(title: "Skip setup for now") { model.skipSetup() }
        }
    }

    private func pickRow(_ service: OnboardingService) -> some View {
        let available = service.id != "whatsapp" || model.whatsAppDetected
        let selected = model.selectedServices.contains(service.id)
        return Button { model.toggleService(service.id) } label: {
            HStack(alignment: .top, spacing: 14) {
                ChoiceBox(selected: selected).padding(.top, 2).opacity(available ? 1 : 0.35)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        ServiceStamp(service: service.id, size: 20)
                        Text(service.name).font(Theme.display(16)).foregroundStyle(Theme.textPrimary)
                    }
                    Text(available ? service.effort : "WhatsApp Desktop not found")
                        .font(Theme.sans(12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text(available ? service.detail : "Install it and sign in, then run setup again from Settings.")
                        .font(Theme.sans(11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.quiet)
        .disabled(!available)
        .accessibilityLabel(service.name)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private func laterRow(_ service: OnboardingService) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ServiceStamp(service: service.id, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(service.name).font(Theme.sans(13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    Text(service.effort).font(Theme.sans(11.5)).foregroundStyle(Theme.textTertiary)
                }
                Text(service.detail)
                    .font(Theme.sans(11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
    }
}

// MARK: - Full Disk Access

private struct AccessStep: View {
    @ObservedObject var model: OnboardingModel

    private var subject: String {
        model.selectedServices.contains("whatsapp") && model.selectedServices.contains("imessage")
            ? "iMessage and WhatsApp keep their history"
            : (model.selectedServices.contains("whatsapp") ? "WhatsApp keeps its history" : "iMessage keeps its history")
    }

    var body: some View {
        let granted = model.access.status == .granted
        StepFrame(kicker: "Step 2 \u{00B7} One permission", title: "Allow access to your messages",
                  subtitle: "\(subject) in a file macOS protects. Full Disk Access lets LLMessenger read it, on this Mac only.") {
            VStack(alignment: .leading, spacing: 18) {
                if granted {
                    StatusLine(kind: .ok, text: "Access granted")
                } else {
                    StatusLine(kind: .waiting, text: "Waiting for access\u{2026}")
                    VStack(alignment: .leading, spacing: 10) {
                        instruction("1", "Open Privacy Settings.")
                        instruction("2", "Switch on LLMessenger in the Full Disk Access list. If it isn\u{2019}t listed, click + and choose it from Applications.")
                    }
                }
                if model.access.status == .needsHelp { helpPanel }
                Caption("macOS will also ask once to use Contacts, only so digests say \u{201C}Anna\u{201D} instead of a phone number.")
            }
        } footer: {
            if granted {
                WizardButton(title: "Continue") { model.continueFromAccess() }
            } else {
                WizardButton(title: "Open Privacy Settings", prominent: model.access.status != .needsHelp) { model.openPrivacySettings() }
                QuietLink(title: "Skip for now, without iMessage") { model.skipAccess() }
            }
        }
    }

    private func instruction(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(n).font(Theme.mono(11, weight: .bold)).foregroundStyle(Theme.textSecondary)
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
            Text(text).font(Theme.sans(12.5)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var helpPanel: some View {
        MarginNote {
            Text("Still not showing up?").font(Theme.display(15)).foregroundStyle(Theme.textPrimary)
            Text("macOS often notices a new permission only after the app restarts. Quit and reopen LLMessenger, then come back here.")
                .font(Theme.sans(12.5)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.appIsInApplicationsFolder {
                Text("LLMessenger is running outside the Applications folder. Move it there first, or macOS may remember a different copy.")
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Quit and Reopen") { model.quitAndReopen() }.buttonStyle(PaperButtonStyle(prominent: true))
                Button("Show in Finder") { model.revealAppInFinder() }.buttonStyle(PaperButtonStyle())
            }
        }
    }
}

// MARK: - AI

private struct AIStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        Group {
            switch model.aiViewMode {
            case .apple:   apple
            case .ollama:  ollama
            case .options: options
            case .current: current
            }
        }
        .task { await model.refreshAIDetection() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            Task { await model.refreshAIDetection() }
        }
    }

    private var apple: some View {
        StepFrame(kicker: "Step 3 \u{00B7} AI model", title: "Digests will use Apple Intelligence",
                  subtitle: "It runs on this Mac. No account, no key, and nothing is sent anywhere.") {
            StatusLine(kind: .ok, text: "Chosen automatically")
        } footer: {
            WizardButton(title: "Continue") { model.useAutomaticAI() }
            QuietLink(title: "Choose a different model") { model.showAIAlternatives = true }
        }
    }

    private var current: some View {
        let name = model.existingCloudProvider?.displayName ?? "your cloud model"
        return StepFrame(kicker: "Step 3 \u{00B7} AI model", title: "Digests will keep using \(name)",
                  subtitle: "You chose it earlier. Your message text is sent to \(name); nothing changes unless you pick something else.") {
            StatusLine(kind: .ok, text: "Already set up")
        } footer: {
            WizardButton(title: "Continue") { model.useAutomaticAI() }
            QuietLink(title: "Choose a different model") { model.showAIAlternatives = true }
        }
    }

    private var ollama: some View {
        StepFrame(kicker: "Step 3 \u{00B7} AI model", title: "Found Ollama on this Mac",
                  subtitle: "Digests will use a model that runs here. Nothing is sent anywhere.") {
            VStack(alignment: .leading, spacing: 8) {
                StatusLine(kind: .ok, text: "Chosen automatically")
                Text("Model").font(Theme.sans(11)).foregroundStyle(Theme.textTertiary).padding(.top, 6)
                Picker("Model", selection: Binding(get: { model.ollamaModel },
                                                   set: { model.chooseOllamaModel($0) })) {
                    ForEach(model.aiDetection.ollamaModels ?? [], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 280, alignment: .leading)
            }
        } footer: {
            WizardButton(title: "Continue") { model.useAutomaticAI() }
            QuietLink(title: "Choose a different model") { model.showAIAlternatives = true }
        }
    }

    private var options: some View {
        StepFrame(kicker: "Step 3 \u{00B7} AI model", title: "Choose how digests get written",
                  subtitle: "LLMessenger needs an AI model to write them. Pick one, or decide later.") {
            VStack(alignment: .leading, spacing: 0) {
                if model.showAIAlternatives { detectedRows }
                installOllama
                Rule().padding(.vertical, 16)
                cloud
            }
        } footer: {
            QuietLink(title: "Decide later") { model.decideAILater() }
            Caption("You can look around first. Digests stay paused until you choose a model.")
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder private var detectedRows: some View {
        if model.aiDetection.appleIntelligence {
            detectedRow("Apple Intelligence", "Runs on this Mac.") { model.aiChoice = .appleIntelligence; model.useAutomaticAI() }
        }
        if let models = model.aiDetection.ollamaModels, !models.isEmpty {
            detectedRow("Ollama", "Found on this Mac, \(models.count) model\(models.count == 1 ? "" : "s").") { model.useDetectedOllama() }
        }
    }

    private func detectedRow(_ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.display(16))
                    Text(detail).font(Theme.sans(12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Use \(title)", action: action).buttonStyle(PaperButtonStyle())
            }
            .padding(.bottom, 14)
            Rule().padding(.bottom, 16)
        }
    }

    private var installOllama: some View {
        VStack(alignment: .leading, spacing: 8) {
            WireLabel("Free and private", color: Theme.ok)
            Text("Install Ollama").font(Theme.display(18))
            Text("Runs the model on this Mac, about 5 minutes. Install Ollama, open it, and download a model. This screen notices when it\u{2019}s ready.")
                .font(Theme.sans(12.5)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button("Get Ollama") { model.openOllamaDownload() }.buttonStyle(PaperButtonStyle(prominent: true))
                StatusLine(kind: .waiting, text: "Looking for Ollama\u{2026}")
            }
            .padding(.top, 2)
        }
    }

    private var cloud: some View {
        VStack(alignment: .leading, spacing: 8) {
            WireLabel("Or use the cloud", color: Theme.standby)
            Text("Anthropic or OpenAI").font(Theme.display(18))
            Text("Needs an API key. Your message text is sent to the provider you pick.")
                .font(Theme.sans(12.5)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach([LLMProvider.anthropic, .openai], id: \.self) { provider in
                    Button(provider.displayName) { model.cloudProvider = provider }
                        .buttonStyle(PaperButtonStyle(prominent: model.cloudProvider == provider))
                }
            }
            .padding(.top, 2)
            SecureField(model.cloudProvider == .anthropic ? "Anthropic API key (sk-ant-\u{2026})" : "OpenAI API key (sk-\u{2026})",
                        text: $model.cloudKey)
                .textFieldStyle(DarkTextFieldStyle())
            HStack {
                Button("Use \(model.cloudProvider.displayName)") { model.useCloud() }
                    .buttonStyle(PaperButtonStyle())
                    .disabled(!model.canUseCloud)
                    .opacity(model.canUseCloud ? 1 : 0.4)
            }
        }
    }
}

// MARK: - Finish

private struct FinishStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        switch model.digestStatus {
        case .notStarted:      ready
        case .building(let detail, let slow): building(detail: detail, slow: slow)
        case .ready:           done
        case .failed(let message, let fix): failed(message: message, fix: fix)
        case .noMessages:      noMessages
        case .paused:          paused
        case .nothingConnected: nothingConnected
        }
    }

    private var willBuild: Bool {
        !model.selectedServices.isEmpty && model.aiChoice != nil && model.aiChoice != .later
    }

    private var ready: some View {
        StepFrame(kicker: "Last step", title: willBuild ? "Build your first digest" : "Save your choices",
                  subtitle: willBuild ? "LLMessenger will read your recent messages and write one digest of what needs you." : nil) {
            VStack(alignment: .leading, spacing: 0) {
                summaryRow("Reads", model.chosenServiceNames.isEmpty ? "Nothing yet" : model.chosenServiceNames.joined(separator: ", "))
                Rule()
                summaryRow("Writes with", model.aiChoice?.summary ?? "Not chosen yet")
                Rule()
                if willBuild {
                    summaryRow("Takes", "Usually under a minute. A few minutes the first time with a model on this Mac.")
                    Rule()
                }
                VStack(alignment: .leading, spacing: 10) {
                    WireLabel("macOS will ask").padding(.top, 14)
                    if model.selectedServices.contains("imessage") {
                        Caption("Contacts, once, so digests say \u{201C}Anna\u{201D} instead of a phone number.")
                    }
                    HStack(spacing: 12) {
                        Caption("Notifications, so you hear when a digest is ready.")
                        Spacer(minLength: 0)
                        Button(model.notificationsRequested ? "Asked" : "Allow notifications") { model.requestNotifications() }
                            .buttonStyle(PaperButtonStyle())
                            .disabled(model.notificationsRequested)
                    }
                }
            }
        } footer: {
            WizardButton(title: willBuild ? "Build my first digest" : "Save and continue") { model.startBuilding() }
            MenuBarLocationNote().padding(.top, 4)
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            WireLabel(label).frame(width: 96, alignment: .leading)
            Text(value).font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }

    private func building(detail: String, slow: Bool) -> some View {
        StepFrame(kicker: "Working", title: "Building your first digest",
                  subtitle: slow ? "This is taking longer than usual. It keeps going if you open LLMessenger."
                                 : "This usually takes under a minute. A model on this Mac can take a few minutes the first time.") {
            StatusLine(kind: .working, text: "\(detail)\u{2026}")
        } footer: {
            WizardButton(title: "Open LLMessenger", prominent: false) { model.finish() }
            Caption("The digest keeps building in the background and appears in the app and your menu bar.")
            MenuBarLocationNote().padding(.top, 4)
        }
    }

    private var done: some View {
        StepFrame(kicker: "Done", kickerColor: Theme.ok, title: "Your first digest is ready",
                  subtitle: "Open it to see who needs you.") {
            EmptyView()
        } footer: {
            WizardButton(title: "Open your first digest") { model.finish() }
            MenuBarLocationNote().padding(.top, 4)
        }
    }

    private func failed(message: String, fix: FirstDigestFix) -> some View {
        StepFrame(kicker: "Needs attention", kickerColor: Theme.signal, title: "Couldn\u{2019}t build your first digest",
                  subtitle: message) {
            EmptyView()
        } footer: {
            switch fix {
            case .chooseAI:  WizardButton(title: "Choose an AI model") { model.fixAI() }
            case .fixAccess: WizardButton(title: "Fix access") { model.fixAccess() }
            case .retry:     WizardButton(title: "Try again") { model.retryBuild() }
            }
            QuietLink(title: "Open LLMessenger anyway") { model.finish() }
        }
    }

    private var noMessages: some View {
        StepFrame(kicker: "Nothing to read yet", title: "No recent messages found",
                  subtitle: "Your digest will appear once new messages arrive. You can also check again now.") {
            EmptyView()
        } footer: {
            WizardButton(title: "Check again") { model.retryBuild() }
            QuietLink(title: "Open LLMessenger") { model.finish() }
        }
    }

    private var paused: some View {
        StepFrame(kicker: "Saved", title: "Digests are paused",
                  subtitle: "Choose an AI model whenever you\u{2019}re ready, in Settings. Until then you can look around.") {
            EmptyView()
        } footer: {
            WizardButton(title: "Open LLMessenger") { model.finish() }
            QuietLink(title: "Choose an AI model now") { model.fixAI() }
            MenuBarLocationNote().padding(.top, 4)
        }
    }

    private var nothingConnected: some View {
        StepFrame(kicker: "Saved", title: "Nothing connected yet",
                  subtitle: "Add a service in Settings \u{2192} Services whenever you\u{2019}re ready. Or look at sample messages first.") {
            EmptyView()
        } footer: {
            WizardButton(title: "Open LLMessenger") { model.finish() }
            QuietLink(title: "See it with sample messages") { model.startDemo() }
            MenuBarLocationNote().padding(.top, 4)
        }
    }
}
