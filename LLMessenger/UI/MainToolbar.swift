// LLMessenger/UI/MainToolbar.swift
//
// Native title-bar toolbar (bridged to NSToolbar via NSHostingController).
// Leading: sidebar toggle + digest back/forward. Center: window title (set via
// .navigationTitle in ContentView). Trailing: search, refresh, service status,
// and a More menu. Replaces the hand-rolled MainChromeBar.

import SwiftUI
import AppKit

struct MainToolbar: ToolbarContent {
    @ObservedObject var appState: AppState
    @Binding var selectedSection: AppSection
    @Binding var deskCollapsed: Bool
    @Binding var showMedia: Bool
    @Binding var showShortcuts: Bool
    var onRetryService: ((String) -> Void)?

    @State private var showingServiceStatus = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                withAnimation(Theme.spring) { deskCollapsed.toggle() }
            } label: {
                Label("Toggle Sidebar", systemImage: "sidebar.left")
            }
            .help("Show or hide the sidebar (⌥⌘S)")
            .keyboardShortcut("s", modifiers: [.command, .option])
        }

        // Back/forward through the digest archive — contextual to Digests.
        if selectedSection == .digests {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    appState.selectAdjacentBrief(newer: false)
                } label: {
                    Label("Older Digest", systemImage: "chevron.left")
                }
                .disabled(!appState.canSelectOlderBrief)
                .help("Older digest (⌘[)")
                .keyboardShortcut("[", modifiers: .command)

                Button {
                    appState.selectAdjacentBrief(newer: true)
                } label: {
                    Label("Newer Digest", systemImage: "chevron.right")
                }
                .disabled(!appState.canSelectNewerBrief)
                .help("Newer digest (⌘])")
                .keyboardShortcut("]", modifiers: .command)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            ToolbarSearchField(appState: appState, selectedSection: $selectedSection)
                .frame(width: 180)

            // Fixed home for the delegation kill switch — was a banner that
            // shifted the whole window's layout whenever it appeared/vanished.
            if appState.hasDelegatedLanes {
                DelegationStatusItem()
            }

            if selectedSection == .digests {
                Button {
                    withAnimation(Theme.spring) { appState.askPanelOpen.toggle() }
                } label: {
                    Label("Ask", systemImage: "text.bubble")
                        .foregroundStyle(appState.askPanelOpen ? Theme.textPrimary : Color.secondary)
                }
                .help(appState.askPanelOpen ? "Close the Ask panel" : "Ask about this digest, or draft a reply")
                // Color alone doesn't announce state to VoiceOver/Increase Contrast.
                .accessibilityAddTraits(appState.askPanelOpen ? [.isButton, .isSelected] : .isButton)
                .accessibilityLabel(appState.askPanelOpen ? "Ask panel, open" : "Ask panel, closed")
            }

            // Routine progress is a toolbar spinner, never a banner.
            if appState.briefGenerationState == .fetching || appState.briefGenerationState == .summarizing {
                ProgressView()
                    .controlSize(.small)
                    .help(appState.briefGenerationState == .fetching
                          ? "Checking messages…" : "Building digest…")
                    .accessibilityLabel("Building digest")
            } else {
                Button {
                    appState.onRequestRefresh?()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Check messages and build a digest now (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
            }

            Button {
                showingServiceStatus.toggle()
            } label: {
                Label(serviceStatusHelp, systemImage: serviceStatusSymbol)
                    .foregroundStyle(serviceIssueCount > 0 ? Theme.standby : Color.secondary)
            }
            .help(serviceStatusHelp)
            .popover(isPresented: $showingServiceStatus, arrowEdge: .bottom) {
                ServiceStatusPopover(
                    services: orderedServices,
                    health: appState.serviceHealth,
                    lastChecked: appState.lastCheckedDate,
                    providerLine: providerLine,
                    onRetry: onRetryService
                )
            }

            Menu {
                Toggle("Media Drawer", isOn: $showMedia.animation(Theme.spring))
                Button("Keyboard Shortcuts") { showShortcuts = true }
                Divider()
                Button("Settings…") { appState.onOpenSettings?() }
                    .keyboardShortcut(",", modifiers: .command)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More actions")
        }
    }

    // MARK: - Delegation status

    /// Fixed toolbar home for the always-relevant delegation kill switch —
    /// a mono wire-label pill (matches the app's chip idiom) with a
    /// pause/resume popover, so the safety control never moves and the
    /// content column never reflows when delegation is armed/disarmed.
    private struct DelegationStatusItem: View {
        @AppStorage(AgentDelegation.killSwitchKey) private var disabled = false
        @State private var showingPopover = false

        var body: some View {
            Button {
                showingPopover.toggle()
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(disabled ? Theme.textTertiary : Theme.standby)
                        .frame(width: 6, height: 6)
                    Text(disabled ? "PAUSED" : "DELEGATED")
                        .font(Theme.mono(10, weight: .semibold))
                        .tracking(0.6)
                }
                .foregroundStyle(disabled ? Theme.textTertiary : Theme.standby)
            }
            .buttonStyle(.plain)
            .help(disabled ? "Auto-send paused — click to resume" : "Auto-send active — click to pause")
            .accessibilityLabel(disabled ? "Auto-send paused" : "Auto-send active")
            .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(disabled ? "Auto-send paused" : "Auto-send active")
                        .font(Theme.sans(12.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(disabled
                         ? "Delegated lanes will resume sending on their own schedule."
                         : "One or more conversations can send without your review.")
                        .font(Theme.sans(11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: 220, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(disabled ? "Resume" : "Pause all") { disabled.toggle() }
                        .buttonStyle(WireActionStyle(tint: disabled ? Theme.standby : Theme.signal, sansLabel: true))
                        .accessibilityLabel(disabled ? "Resume auto-send for delegated lanes" : "Pause all delegated auto-sends")
                }
                .padding(14)
            }
        }
    }

    // MARK: - Service status helpers

    private var orderedServices: [String] {
        ["imessage", "signal", "telegram", "slack"]
    }

    private var serviceIssueCount: Int {
        orderedServices.filter {
            appState.serviceHealth[$0] == .warning || appState.serviceHealth[$0] == .error
        }.count
    }

    private var serviceStatusSymbol: String {
        if serviceIssueCount > 0 { return "exclamationmark.triangle" }
        if appState.serviceHealth.values.contains(.ok) { return "checkmark.circle" }
        return "circle.dashed"
    }

    private var serviceStatusHelp: String {
        if serviceIssueCount > 0 {
            return "\(serviceIssueCount) service issue\(serviceIssueCount == 1 ? "" : "s")"
        }
        if appState.serviceHealth.values.contains(.ok) { return "Services connected" }
        return "Service status"
    }

    /// Persistent AI provenance — replaces the always-on disclaimer footer.
    private var providerLine: String {
        guard appState.isLLMConfigured else { return "No AI backend configured" }
        let where_ = appState.llmClient.isLocal ? "on this Mac" : "via \(appState.llmProvider?.rawValue.capitalized ?? "cloud provider")"
        return "Digests: \(appState.llmModel) \(where_) · AI-generated, may miss nuance"
    }
}

// MARK: - Toolbar search field

/// Real NSSearchField in the toolbar. Typing searches messages and digests via
/// the archive pipeline; starting a search switches to the Digests section so
/// results are visible next to the selected digest.
/// ponytail: fixed 180pt, not the collapsing NSSearchToolbarItem — upgrade if
/// toolbar space gets tight on small windows.
struct ToolbarSearchField: NSViewRepresentable {
    @ObservedObject var appState: AppState
    @Binding var selectedSection: AppSection

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search"
        field.delegate = context.coordinator
        field.controlSize = .regular
        field.sendsSearchStringImmediately = true
        appState.focusArchiveSearch = { [weak field] in
            field?.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != appState.archiveSearchQuery {
            field.stringValue = appState.archiveSearchQuery
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private let parent: ToolbarSearchField

        init(_ parent: ToolbarSearchField) {
            self.parent = parent
        }

        // Typing navigates the window as a side effect (Digests must be open to
        // see results) — soften the user-control cost by remembering where the
        // user actually was and returning them there when the query clears,
        // rather than leaving them stranded in Digests after search.
        private var preSearchSection: AppSection?

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            let value = field.stringValue
            parent.appState.archiveSearchQuery = value
            if !value.isEmpty {
                if parent.selectedSection != .digests {
                    preSearchSection = parent.selectedSection
                    parent.selectedSection = .digests
                }
            } else if let priorSection = preSearchSection {
                parent.selectedSection = priorSection
                preSearchSection = nil
            }
        }
    }
}

// MARK: - Service status popover

struct ServiceStatusPopover: View {
    let services: [String]
    let health: [String: AdapterHealthResult.Status]
    let lastChecked: Date?
    var providerLine: String? = nil
    let onRetry: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Services")
                    .font(Theme.sans(13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let lastChecked {
                    Text(relativeLabel(lastChecked))
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(14)

            Rule()

            ForEach(services, id: \.self) { service in
                HStack(spacing: 9) {
                    Circle()
                        .fill(statusColor(health[service]))
                        .frame(width: 6, height: 6)
                    Text(Theme.serviceName(service))
                        .font(Theme.sans(12.5))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(statusLabel(health[service]))
                        .font(Theme.sans(11.5))
                        .foregroundStyle(Theme.textTertiary)
                    if health[service] == .warning || health[service] == .error {
                        Button { onRetry?(service) } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Retry \(Theme.serviceName(service))")
                        .accessibilityLabel("Retry \(Theme.serviceName(service))")
                    }
                }
                .frame(height: 34)
                .padding(.horizontal, 14)
            }

            if let providerLine {
                Rule()
                Text(providerLine)
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
        .frame(width: 260)
        .background(Theme.sidebar)
    }

    private func statusLabel(_ status: AdapterHealthResult.Status?) -> String {
        switch status {
        case .ok: return "Connected"
        case .warning: return "Needs attention"
        case .error: return "Unavailable"
        case nil: return "Not configured"
        }
    }

    private func statusColor(_ status: AdapterHealthResult.Status?) -> Color {
        switch status {
        case .ok: return Theme.ok
        case .warning: return Theme.standby
        case .error: return Theme.signal
        case nil: return Theme.textTertiary.opacity(0.4)
        }
    }

    private func relativeLabel(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
