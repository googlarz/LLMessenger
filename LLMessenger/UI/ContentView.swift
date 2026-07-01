// LLMessenger/UI/ContentView.swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel
    // Brief archive sidebar — toggled by hamburger / ⌥⌘S.
    @State private var sidebarCollapsed = true
    // Desk panel (Act/Digest/Activity) — shown on the left alongside the brief.
    @State private var deskCollapsed = false
    @State private var showMedia = false
    @State private var showSearch = false
    @State private var showShortcuts = false
    var onRetryService: ((String) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            MainChromeBar(
                sidebarCollapsed: $sidebarCollapsed,
                showMedia: $showMedia,
                showSearch: $showSearch,
                deskCollapsed: $deskCollapsed,
                onRetryService: onRetryService
            )
            Rule()

            // One global surface for errors — ~30 lastError assignments used to vanish unless
            // a brief happened to be open. Now every one is visible and dismissible.
            if let err = appState.lastError, !err.isEmpty {
                NoticeBanner(
                    text: err,
                    onRetry: { appState.onRequestRefresh?() },
                    onDismiss: { appState.lastError = nil }
                )
                Rule()
            }

            if let receipt = appState.userReceipt {
                ReceiptBanner(receipt: receipt, onDismiss: { appState.clearReceipt() })
                Rule()
            }

            if shouldShowFirstRealDigestMoment {
                FirstRealDigestSuccessView()
                Rule()
            }

            GeometryReader { proxy in
                let layout = deskLayout(for: proxy.size.width)
                let deskWidth = deskWidth(for: proxy.size.width, layout: layout)
                HStack(spacing: 0) {
                    // Brief archive (power-user drawer, collapsed by default)
                    if !sidebarCollapsed {
                        BriefListView(showSearch: showSearch)
                            .frame(width: archiveWidth(for: proxy.size.width))
                            .background(Theme.sidebar)
                            .transition(.move(edge: .leading).combined(with: .opacity))

                        Theme.border.frame(width: Theme.hairline)
                            .transition(.opacity)
                    }

                // Desk panel — persistent left sidebar (Act/Digest/Activity)
                    if !deskCollapsed {
                        DeskView(layout: layout)
                            .frame(width: deskWidth)
                            .background(Theme.sidebar)
                            .transition(.move(edge: .leading).combined(with: .opacity))

                        Theme.border.frame(width: Theme.hairline)
                            .transition(.opacity)
                    }

                    // Main content — brief reader (always visible)
                    if appState.selectedBrief != nil {
                        ChatPanelView()
                            .background(Theme.bg)
                    } else {
                        NoBriefPlaceholder(deskCollapsed: $deskCollapsed)
                            .background(Theme.bg)
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
        .ignoresSafeArea(.all, edges: .top)
        .onChange(of: showSearch) { searching in
            if searching { withAnimation(Theme.spring) { sidebarCollapsed = false } }
        }
        // Scoped document shortcuts. J/K belongs to the Act feed while Desk is open;
        // when Desk is hidden, the reader owns J/K for digest navigation.
        .background {
            KeyboardShortcutMonitor(isEnabled: true) { event in
                let key = event.normalizedKey
                if key == "?" || (key == "/" && event.modifierFlags.contains(.shift)) {
                    showShortcuts.toggle()
                    return true
                }
                guard deskCollapsed, event.hasNoCommandOptionControl else { return false }
                if key == "j" {
                    navigateBriefs(offset: 1)
                    return true
                }
                if key == "k" {
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
        .animation(Theme.spring, value: sidebarCollapsed)
        .animation(Theme.spring, value: deskCollapsed)
        .animation(Theme.spring, value: showMedia)
        // Auto-select the latest brief the first time briefs arrive.
        .onChange(of: appState.briefs.count) { count in
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

    // MARK: - Navigation helpers

    private var briefsNewestFirst: [Brief] {
        appState.briefs.sorted { $0.createdAt > $1.createdAt }
    }

    private func navigateBriefs(offset: Int) {
        let briefs = briefsNewestFirst
        guard !briefs.isEmpty else { return }
        let idx = briefs.firstIndex { $0.id == appState.selectedBriefID } ?? 0
        let target = (idx + offset + briefs.count) % briefs.count
        withAnimation(Theme.quick) { appState.selectedBriefID = briefs[target].id }
    }

    private func deskLayout(for width: CGFloat) -> DeskLayout {
        width < 980 ? .compact : .regular
    }

    private func deskWidth(for width: CGFloat, layout: DeskLayout) -> CGFloat {
        switch layout {
        case .compact:
            return min(300, max(272, width * 0.30))
        case .regular:
            return min(380, max(320, width * 0.28))
        }
    }

    private func archiveWidth(for width: CGFloat) -> CGFloat {
        min(300, max(232, width * 0.22))
    }

    private func mediaWidth(for width: CGFloat) -> CGFloat {
        min(300, max(240, width * 0.22))
    }
}

// MARK: - No-brief placeholder

private struct NoBriefPlaceholder: View {
    @EnvironmentObject var appState: AppState
    @Binding var deskCollapsed: Bool

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
                Text("Open a digest with J/K, ⌘[ / ⌘], or pick one from the inbox.")
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                if deskCollapsed {
                    Button("Open inbox") {
                        withAnimation(Theme.spring) { deskCollapsed = false }
                    }
                    .buttonStyle(PaperButtonStyle())
                    .padding(.top, 4)
                }
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
        if appState.serviceHealthMap.isEmpty {
            return "Waiting for Signal, Telegram, iMessage, or Slack"
        }
        let failing = appState.serviceHealthMap.values.filter { $0.status == "error" }.count
        if failing > 0 {
            return "\(failing) service\(failing == 1 ? "" : "s") need attention"
        }
        let ok = appState.serviceHealthMap.values.filter { $0.status == "ok" }.count
        return ok > 0 ? "\(ok) service\(ok == 1 ? "" : "s") connected" : "Checking service permissions"
    }

    private var serviceSetupState: SetupCheck.State {
        if appState.serviceHealthMap.values.contains(where: { $0.status == "error" }) { return .needsSetup }
        if appState.serviceHealthMap.values.contains(where: { $0.status == "ok" }) { return .ready }
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
                .font(Theme.mono(9.5, weight: .semibold))
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

// MARK: - First real digest success

private struct FirstRealDigestSuccessView: View {
    @EnvironmentObject var appState: AppState

    private var latestBrief: Brief? {
        appState.briefs.sorted { $0.createdAt > $1.createdAt }.first
    }

    private var cardStats: (cards: Int, replies: Int, sourced: Int) {
        guard let json = BriefJSON.decodeLenient(from: latestBrief?.openingSummary) else {
            return (0, 0, 0)
        }
        return (
            json.cards.count,
            json.cards.filter(\.needsReply).count,
            json.cards.filter { !$0.sourceMessageIds.isEmpty }.count
        )
    }

    var body: some View {
        let stats = cardStats
        HStack(alignment: .top, spacing: 12) {
            Theme.ok.frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))

            VStack(alignment: .leading, spacing: 5) {
                WireLabel("First real digest ready", color: Theme.ok)
                Text(successLine(stats))
                    .font(Theme.sans(12.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing was sent. Drafts stay review-first, and every important card can show its local sources.")
                    .font(Theme.sans(11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                firstDigestGuide
                    .padding(.top, 3)
            }

            Spacer(minLength: 8)

            if let latestBrief {
                Button("OPEN") {
                    appState.selectedBriefID = latestBrief.id
                    appState.acknowledgeFirstRealDigest()
                }
                .buttonStyle(PaperButtonStyle(prominent: true))
            }

            Button("GOT IT") {
                appState.acknowledgeFirstRealDigest()
            }
            .buttonStyle(WireActionStyle())
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 10)
        .background(Theme.ok.opacity(0.045))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("First real digest ready. \(successLine(cardStats)) Nothing was sent.")
    }

    private func successLine(_ stats: (cards: Int, replies: Int, sourced: Int)) -> String {
        let held = appState.heldBackCount
        let cards = "\(stats.cards) card\(stats.cards == 1 ? "" : "s")"
        let replies = "\(stats.replies) need\(stats.replies == 1 ? "s" : "") you"
        let sources = "\(stats.sourced) source-backed"
        let heldBack = "\(held) held back"
        return "\(cards), \(replies), \(sources), \(heldBack)."
    }

    private var firstDigestGuide: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                guideStep("1", "Open sources")
                guideStep("2", "Mark one done")
                guideStep("3", "Draft only if ready")
                guideStep("4", "Quiet noise")
            }
            VStack(alignment: .leading, spacing: 4) {
                guideStep("1", "Open sources")
                guideStep("2", "Mark one done")
                guideStep("3", "Draft only if ready")
                guideStep("4", "Quiet noise")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Suggested first digest steps: open sources, mark one done, draft only if ready, quiet noise.")
    }

    private func guideStep(_ number: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(number)
                .font(Theme.mono(9, weight: .bold))
                .foregroundStyle(Theme.ok)
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(Theme.ok.opacity(0.45), lineWidth: 1))
            Text(text)
                .font(Theme.mono(9.5, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize()
        }
    }
}

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

private struct ReceiptBanner: View {
    let receipt: UserReceipt
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Theme.ok.frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))
            VStack(alignment: .leading, spacing: 3) {
                WireLabel("Saved", color: Theme.ok)
                Text(receipt.text)
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let actionTitle = receipt.actionTitle, let action = receipt.action {
                Button(actionTitle.uppercased()) {
                    action()
                    onDismiss()
                }
                .buttonStyle(WireActionStyle(tint: Theme.ok))
            }
            Button("DISMISS", action: onDismiss)
                .buttonStyle(WireActionStyle())
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 9)
        .background(Theme.ok.opacity(0.035))
        .accessibilityElement(children: .contain)
    }
}
