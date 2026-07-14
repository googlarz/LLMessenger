// LLMessenger/UI/ContentView.swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel
    // Sidebar rail + main content, persisted across launches.
    @AppStorage("selectedSection") private var selectedSection: AppSection = .act
    @AppStorage("sidebarCollapsed") private var deskCollapsed = false
    @State private var showMedia = false
    @State private var showShortcuts = false
    var onRetryService: ((String) -> Void)? = nil

    /// Below this width, the sidebar rail auto-hides so the remaining columns
    /// (e.g. digest archive + reader) get the room instead of everything squeezing.
    private static let narrowWindowThreshold: CGFloat = 900
    private static let railWidth: CGFloat = 190

    /// At most one banner is ever shown — a stack of "notices" reads like a
    /// debug console, and a queue means the important one never gets buried
    /// under a routine one. Priority: error > pipeline stall > demo transition.
    /// The kill switch and "first digest ready" moments are NOT banners
    /// anymore — see the toolbar status item and the receipt toast below.
    private enum TopBanner { case error(String), pipeline, demoTransition }
    private var activeBanner: TopBanner? {
        if let err = appState.lastError, !err.isEmpty { return .error(err) }
        if appState.briefPipelineHealth.hasIssues { return .pipeline }
        if appState.isDemoTransitioning { return .demoTransition }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let hideSidebar = deskCollapsed || proxy.size.width < Self.narrowWindowThreshold
                HStack(spacing: 0) {
                    // Persistent navigation rail — Act, Digests, Activity. Content-free;
                    // the selected section drives everything to its right. Full-height:
                    // banners live in the content column so they never cross it.
                    if !hideSidebar {
                        DeskView(selectedTab: $selectedSection)
                            .frame(width: Self.railWidth)
                            .background(Theme.sidebar)
                            .transition(.move(edge: .leading).combined(with: .opacity))

                        Theme.border.frame(width: Theme.hairline)
                            .transition(.opacity)
                    }

                    VStack(spacing: 0) {
                        if let banner = activeBanner {
                            bannerView(banner)
                            Rule()
                        }
                        sectionContent(width: proxy.size.width)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if showMedia {
                        Theme.border.frame(width: Theme.hairline)
                            .transition(.opacity)

                        MediaPanelView(onClose: { withAnimation(Theme.spring) { showMedia = false } })
                            .frame(width: mediaWidth(for: proxy.size.width))
                            .background(Theme.sidebar)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            }
        }
        .background(Theme.bg)
        // Routine success is a floating toast that never displaces content;
        // it auto-dismisses and carries its optional follow-up action.
        .overlay(alignment: .bottom) {
            if let receipt = appState.userReceipt {
                ReceiptToast(receipt: receipt, onDismiss: { appState.clearReceipt() })
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: appState.userReceipt?.id)
        // The one-time "first real digest" moment fires as a toast instead of a
        // persistent banner — its stat narration ("4 cards · 3 need you...")
        // duplicates numbers already visible in the sidebar badge and header.
        .onChange(of: shouldShowFirstRealDigestMoment) { _, shouldShow in
            guard shouldShow else { return }
            appState.showReceipt("First digest ready.")
            appState.acknowledgeFirstRealDigest()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("LLMessenger main window")
        .toolbar {
            MainToolbar(
                appState: appState,
                selectedSection: $selectedSection,
                deskCollapsed: $deskCollapsed,
                showMedia: $showMedia,
                showShortcuts: $showShortcuts,
                onRetryService: onRetryService
            )
        }
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        // Scoped document shortcuts. J/K navigates digests only while the Digests
        // section is open — Act owns its own selection via ActFeedView.
        .background {
            KeyboardShortcutMonitor(isEnabled: true) { event in
                let key = event.normalizedKey
                if key == "?" || (key == "/" && event.modifierFlags.contains(.shift)) {
                    showShortcuts.toggle()
                    return true
                }
                if key == "f", event.modifierFlags.contains(.command) {
                    selectedSection = .digests
                    appState.focusArchiveSearch?()
                    return true
                }
                guard selectedSection == .digests, event.hasNoCommandOptionControl else { return false }
                // ↑/↓ are synonyms for K/J — the Mac list-navigation convention
                // (Mail, Notes, NetNewsWire) must keep working here too.
                if key == "j" || event.keyCode == 125 {
                    navigateBriefs(offset: 1)
                    return true
                }
                if key == "k" || event.keyCode == 126 {
                    navigateBriefs(offset: -1)
                    return true
                }
                return false
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .sheet(isPresented: $showShortcuts) {
            KeyboardShortcutsSheet(isPresented: $showShortcuts)
        }
        .animation(Theme.spring, value: deskCollapsed)
        .animation(Theme.spring, value: showMedia)
        .animation(Theme.spring, value: selectedSection)
        // Auto-select the latest brief the first time briefs arrive.
        .onChange(of: appState.briefs.count) { _, count in
            if appState.selectedBriefID == nil, count > 0 {
                appState.selectedBriefID = appState.briefs
                    .sorted { $0.createdAt > $1.createdAt }
                    .first?.id
            }
        }
    }

    private var shouldShowFirstRealDigestMoment: Bool {
        !DemoSeeder.isActive &&
        !appState.briefs.isEmpty &&
        !appState.productLoveMetrics.firstRealDigestAcknowledged
    }

    @ViewBuilder
    private func bannerView(_ banner: TopBanner) -> some View {
        switch banner {
        case .error(let text):
            NoticeBanner(
                text: text,
                onRetry: { appState.onRequestRefresh?() },
                onDismiss: { appState.lastError = nil }
            )
        case .pipeline:
            BriefPipelineBanner(health: appState.briefPipelineHealth) {
                appState.retryBlockedBriefJobs()
            }
        case .demoTransition:
            DemoTransitionBanner()
        }
    }

    // MARK: - Window title

    private var windowTitle: String {
        switch selectedSection {
        case .act: return "Act"
        case .digests: return "Digests"
        case .activity: return "Activity"
        }
    }

    private var windowSubtitle: String {
        guard selectedSection == .digests, let brief = appState.selectedBrief else { return "" }
        let f = DateFormatter()
        let cal = Calendar.current
        if cal.isDateInToday(brief.createdAt) {
            f.dateFormat = "'Today' HH:mm"
        } else if cal.isDateInYesterday(brief.createdAt) {
            f.dateFormat = "'Yesterday' HH:mm"
        } else {
            f.dateFormat = "EEE d MMM HH:mm"
        }
        return f.string(from: brief.createdAt)
    }

    // MARK: - Navigation helpers

    private var briefsNewestFirst: [Brief] {
        appState.briefs.sorted { $0.createdAt > $1.createdAt }
    }

    private func navigateBriefs(offset: Int) {
        let briefs = briefsNewestFirst
        guard !briefs.isEmpty else { return }
        let idx = briefs.firstIndex { $0.id == appState.selectedBriefID } ?? 0
        // Clamp at the ends — arrow-key lists never teleport oldest-to-newest.
        let target = min(max(idx + offset, 0), briefs.count - 1)
        withAnimation(Theme.quick) { appState.selectedBriefID = briefs[target].id }
    }

    /// Middle column width for the Digests archive list (when Digests is selected).
    private func archiveWidth(for width: CGFloat) -> CGFloat {
        min(380, max(320, width * 0.28))
    }

    private func mediaWidth(for width: CGFloat) -> CGFloat {
        min(300, max(240, width * 0.22))
    }

    /// Routes the main content area to match the sidebar's selected section — the
    /// fix for the core navigation bug: selection and content were previously
    /// unrelated (the reader always showed regardless of which tab was active).
    @ViewBuilder
    private func sectionContent(width: CGFloat) -> some View {
        switch selectedSection {
        case .act:
            ActWorkspaceView()
                .background(Theme.bg)
        case .digests:
            HStack(spacing: 0) {
                // Theme.bg, not Theme.sidebar — the archive is content (a message
                // list), not a second nav rail. Matching the rail's background
                // was the exact "am I looking at two sidebars?" bug.
                BriefListView()
                    .frame(width: archiveWidth(for: width))
                    .background(Theme.bg)
                Theme.border.frame(width: Theme.hairline)
                if appState.selectedBrief != nil {
                    ChatPanelView()
                        .background(Theme.bg)
                } else {
                    NoBriefPlaceholder()
                        .background(Theme.bg)
                }
            }
        case .activity:
            ActivityView()
                .background(Theme.bg)
        }
    }
}

// MARK: - No-brief placeholder

private struct NoBriefPlaceholder: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        // First run (never had a brief) → an alive "preparing" skeleton that morphs into the
        // real brief, instead of a dead void. Had-briefs-but-none-open → a quiet "nothing open".
        if appState.briefs.isEmpty {
            FirstBriefPreparingView()
        } else {
            VStack(spacing: 10) {
                Image(systemName: "newspaper")
                    .font(Theme.sans(32, weight: .thin))
                    .foregroundStyle(Theme.textTertiary.opacity(0.5))
                    .padding(.bottom, 4)
                WireLabel("Desk")
                Text("Nothing open")
                    .font(Theme.display(22))
                    .foregroundStyle(Theme.textSecondary)
                Text("Open a digest with J/K, ⌘[ / ⌘], or pick one from the archive.")
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - First-brief preparing state

/// Shown on the very first run while the first brief is being built. A shimmering skeleton
/// of the real brief layout (masthead + two entries) so the moment feels alive and previews
/// what's coming, rather than a black void with one line of text.
private struct FirstBriefPreparingView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var failed: Bool { appState.briefGenerationState == .failed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.signal)
                    .frame(width: 6, height: 6)
                    .opacity(failed ? 1 : (pulse ? 1 : 0.25))
                WireLabel(failed ? "Couldn't build your first digest" : "Preparing your first digest",
                          color: failed ? Theme.signal : Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 22)

            if failed {
                // Don't strand the user in an infinite shimmer when the build fails — show what
                // went wrong and a way out.
                Text(friendlyError)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Try again") { appState.onRequestRefresh?() }
                        .buttonStyle(PaperButtonStyle())
                    if looksLikeConfigError {
                        Button("Open Settings") { appState.onOpenSettings?() }
                            .buttonStyle(WireActionStyle())
                    }
                }
                .padding(.top, 16)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    bar(230, 24)
                    bar(300, 11).padding(.top, 12)
                    Rule().padding(.vertical, 20)
                    ForEach(0..<2, id: \.self) { i in
                        bar(270, 14)
                        bar(440, 10).padding(.top, 9)
                        bar(360, 10).padding(.top, 5)
                        if i == 0 { Rule().padding(.vertical, 18) }
                    }
                }
                .opacity(reduceMotion ? 0.9 : (pulse ? 1 : 0.5))
                .animation(reduceMotion ? nil : .easeInOut(duration: 1.15).repeatForever(autoreverses: true), value: pulse)

                Text(preparingLine)
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 26)

                VStack(alignment: .leading, spacing: 7) {
                    ForEach(setupChecks) { check in
                        setupRow(check)
                    }
                }
                .padding(.top, 14)

                if appState.briefs.isEmpty && !DemoSeeder.isActive {
                    HStack(spacing: 10) {
                        Button("Explore demo while this runs") {
                            appState.startDemoMode()
                        }
                        .buttonStyle(PaperButtonStyle(prominent: true))
                        Button("Open Settings") {
                            appState.onOpenSettings?()
                        }
                        .buttonStyle(WireActionStyle())
                    }
                    .padding(.top, 18)
                }
            }

            // The moment a user decides whether to trust this with their messages — say the
            // local-first promise here, not just in PRIVACY.md.
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.ok)
                Text(safetyLine)
                    .font(Theme.sans(11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 30)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { if !reduceMotion { pulse = true } }
    }

    private var friendlyError: String {
        let e = (appState.lastError ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return e.isEmpty ? "Something went wrong building your first digest. You can try again." : e
    }

    private var looksLikeConfigError: Bool {
        if !appState.isLLMConfigured { return true }
        let e = (appState.lastError ?? "").lowercased()
        return ["backend", "model", "provider", "api key", "ollama", "openai", "anthropic"].contains { e.contains($0) }
    }

    private var safetyLine: String {
        guard appState.isLLMConfigured else {
            return "Connect a local model to keep summaries on this Mac, or choose a cloud provider explicitly."
        }
        if appState.llmClient.isLocal {
            return appState.hasDelegatedLanes
                ? "Summaries run on this Mac. Delegated sends still show an undo window."
                : "Summaries run on this Mac. Manual sends stage with undo."
        }
        return appState.hasDelegatedLanes
            ? "Cloud summaries use your selected provider. Delegated sends still show an undo window."
            : "Cloud summaries use your selected provider. Manual sends stage with undo."
    }

    private var preparingLine: String {
        if !appState.isLLMConfigured {
            return "Choose an AI backend to build your first digest. Local models keep message content on this Mac."
        }
        return "Reading your messages, contacts, and context. You can explore the sample command center while the first real digest is loading."
    }

    private var setupChecks: [SetupCheck] {
        [
            SetupCheck(
                label: "AI",
                value: aiSetupText,
                state: appState.isLLMConfigured ? .ready : .needsSetup
            ),
            SetupCheck(
                label: "Services",
                value: serviceSetupText,
                state: serviceSetupState
            ),
            SetupCheck(
                label: "Messages",
                value: messageSetupText,
                state: appState.briefs.isEmpty ? .waiting : .ready
            ),
            SetupCheck(
                label: "Privacy",
                value: privacySetupText,
                state: .ready
            )
        ]
    }

    private var aiSetupText: String {
        if appState.isLLMConfigured {
            return appState.llmClient.isLocal ? "Local model selected" : "Cloud provider selected with consent"
        }
        return "Needs a local model or provider key"
    }

    private var serviceSetupText: String {
        if appState.serviceHealth.isEmpty {
            return "Waiting for Signal, Telegram, iMessage, or Slack"
        }
        let failing = appState.serviceHealth.values.filter { $0 == .error }.count
        if failing > 0 {
            return "\(failing) service\(failing == 1 ? "" : "s") need attention"
        }
        let ok = appState.serviceHealth.values.filter { $0 == .ok }.count
        return ok > 0 ? "\(ok) service\(ok == 1 ? "" : "s") connected" : "Checking service permissions"
    }

    private var serviceSetupState: SetupCheck.State {
        if appState.serviceHealth.values.contains(.error) { return .needsSetup }
        if appState.serviceHealth.values.contains(.ok) { return .ready }
        return .waiting
    }

    private var messageSetupText: String {
        if !appState.briefs.isEmpty { return "First digest is ready" }
        if let last = appState.lastCheckedDate {
            return "Last checked \(relativeSetupTime(last)); waiting for digest"
        }
        return "Waiting for the first sync"
    }

    private var privacySetupText: String {
        if appState.llmClient.isLocal {
            return "Message content stays on this Mac"
        }
        return "Drafts are review-first; nothing auto-sends by default"
    }

    private func bar(_ width: CGFloat, _ height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Theme.surfaceHigh)
            .frame(width: width, height: height)
    }

    private func setupRow(_ check: SetupCheck) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(check.state.color)
                .frame(width: 6, height: 6)
                .padding(.top, 4)
                .accessibilityHidden(true)
            Text(check.label.uppercased())
                .font(Theme.mono(10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 66, alignment: .leading)
            Text(check.value)
                .font(Theme.sans(11.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func relativeSetupTime(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = Int(seconds / 3600)
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}

private struct SetupCheck: Identifiable {
    enum State {
        case ready
        case waiting
        case needsSetup

        var color: Color {
            switch self {
            case .ready: return Theme.ok
            case .waiting: return Theme.textTertiary
            case .needsSetup: return Theme.signal
            }
        }
    }

    let label: String
    let value: String
    let state: State

    var id: String { label }
}

// The persistent "First digest ready · 4 cards · 3 need you..." banner was
// retired — the same moment now fires as a receipt toast (see body above),
// since the stat narration duplicated numbers already visible in the sidebar
// badge and the digest masthead.

// MARK: - Global notice banner

/// A calm, dismissible error/notice surface in the editorial idiom (vermilion rule + label +
/// plain sentence). Mirrors BriefHeaderView.noticeRow.
private struct NoticeBanner: View {
    let text: String
    var onRetry: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Theme.signal.frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))
            VStack(alignment: .leading, spacing: 3) {
                WireLabel("Notice", color: Theme.signal)
                Text(text)
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let onRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(WireActionStyle())
            }
            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss notice")
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 9)
        .background(Theme.signalWash)
    }
}

private struct BriefPipelineBanner: View {
    let health: BriefPipelineHealth
    let onRetry: () -> Void
    @State private var retryHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Theme.signal.frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))
            VStack(alignment: .leading, spacing: 3) {
                WireLabel(title, color: Theme.signal)
                Text(message)
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if health.deadLetterJobCount > 0 {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(retryHovered ? Theme.textPrimary : Theme.signal)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.controlRadius)
                                .fill(retryHovered ? Theme.surfaceHigh : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Retry preserved digest messages")
                .accessibilityLabel("Retry preserved digest messages")
                .onHover { retryHovered = $0 }
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 9)
        .background(Theme.signalWash)
    }

    private var title: String {
        health.deadLetterJobCount > 0 ? "Digest pipeline paused" : "Digest retry scheduled"
    }

    private var message: String {
        let count = health.pendingMessageCount
        let noun = count == 1 ? "message is" : "messages are"
        if health.deadLetterJobCount > 0 {
            return "\(count) \(noun) preserved after repeated AI failures. Retry when the provider is available."
        }
        return "\(count) \(noun) preserved and will be retried automatically."
    }
}

/// Floating confirmation for routine success — overlays the content instead of
/// pushing it down, and dismisses itself unless the user is hovering it.
private struct ReceiptToast: View {
    let receipt: UserReceipt
    let onDismiss: () -> Void
    @State private var hovering = false
    @State private var deadline = Date()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ok)
            Text(receipt.text)
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            if let actionTitle = receipt.actionTitle, let action = receipt.action {
                Button(actionTitle.uppercased()) {
                    action()
                    onDismiss()
                }
                .buttonStyle(WireActionStyle(tint: Theme.ok))
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss confirmation")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius + 2)
                .fill(Theme.surfaceHigh)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius + 2)
                .strokeBorder(Theme.border, lineWidth: Theme.hairline)
        )
        .frame(maxWidth: 480)
        // Hovering past the 6s deadline used to make the toast sticky forever
        // (the deadline was only checked once, at expiry). Dismiss the instant
        // the pointer leaves if that deadline has already passed.
        .onHover { isHovering in
            hovering = isHovering
            if !isHovering, Date() >= deadline { onDismiss() }
        }
        .task(id: receipt.id) {
            deadline = Date().addingTimeInterval(6)
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !hovering { onDismiss() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved: \(receipt.text)")
    }
}
