import SwiftUI

/// Compact document toolbar. Connection detail stays behind the status button so the
/// current digest and its navigation remain the visual center of gravity.
struct MainChromeBar: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel
    @Binding var showMedia: Bool
    /// Binding into ContentView — toggles the persistent Desk panel (Act/Digest/Activity).
    var deskCollapsed: Binding<Bool>? = nil
    var onRetryService: ((String) -> Void)? = nil

    @State private var showingBriefPicker = false
    @State private var showingServiceStatus = false
    @State private var focusBriefSearch = false
    @State private var briefPickerHovered = false

    var body: some View {
        ZStack {
            Theme.sidebar

            HStack(spacing: 10) {
                // Traffic-lights spacer
                Spacer().frame(width: 70)

                if let deskCollapsed {
                    chromeIcon("sidebar.left",
                               active: !deskCollapsed.wrappedValue,
                               help: "Show or hide the sidebar (⌥⌘S)") {
                        withAnimation(Theme.spring) { deskCollapsed.wrappedValue.toggle() }
                    }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                }

                serviceStatusButton

                Spacer()

                chromeIcon("magnifyingglass", active: showingBriefPicker, help: "Search messages and digests (⌘F)") {
                    focusBriefSearch = true
                    showingBriefPicker = true
                }
                .keyboardShortcut("f", modifiers: .command)

                chromeIcon("photo.on.rectangle.angled", active: showMedia, help: "Media drawer") {
                    withAnimation(Theme.spring) { showMedia.toggle() }
                }
                .padding(.trailing, 14)
            }

            briefPickerCluster
        }
        .frame(height: 40)
    }

    private func chromeIcon(_ symbol: String, active: Bool, help: String,
                            action: @escaping () -> Void) -> some View {
        ChromeIconButton(symbol: symbol, active: active, help: help, action: action)
    }

    private var serviceStatusButton: some View {
        Button { showingServiceStatus.toggle() } label: {
            Image(systemName: serviceStatusSymbol)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(serviceIssueCount > 0 ? Theme.standby : Theme.textTertiary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Theme.controlRadius)
                        .fill(showingServiceStatus ? Theme.surfaceHigh : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(serviceStatusHelp)
        .accessibilityLabel(serviceStatusHelp)
        .popover(isPresented: $showingServiceStatus, arrowEdge: .bottom) {
            ServiceStatusPopover(
                services: orderedServices,
                health: appState.serviceHealth,
                lastChecked: appState.lastCheckedDate,
                onRetry: onRetryService
            )
        }
    }

    // MARK: - Brief picker cluster

    private var briefPickerCluster: some View {
        HStack(spacing: 0) {
            arrowButton("chevron.left", enabled: canGoOlder, key: "[") {
                navigate(offset: 1)  // older = later index in newest-first list
            }

            Button {
                focusBriefSearch = false
                showingBriefPicker.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text(currentBriefLabel.uppercased())
                        .font(Theme.mono(10.5, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.textPrimary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: Theme.controlRadius)
                        .fill(briefPickerHovered ? Theme.surfaceHigh : Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.controlRadius)
                        .strokeBorder(briefPickerHovered ? Theme.textTertiary : Theme.border, lineWidth: Theme.hairline)
                )
            }
            .buttonStyle(.plain)
            .help("Browse the digest archive")
            .animation(Theme.quick, value: briefPickerHovered)
            .onHover { briefPickerHovered = $0 }
            .popover(isPresented: $showingBriefPicker, arrowEdge: .bottom) {
                BriefListView(showSearch: focusBriefSearch)
                    .environmentObject(appState)
                    .environmentObject(chatViewModel)
                    .frame(width: 320, height: 460)
            }

            arrowButton("chevron.right", enabled: canGoNewer, key: "]") {
                navigate(offset: -1)  // newer = earlier index in newest-first list
            }
        }
        .onChange(of: showingBriefPicker) { _, isShowing in
            if !isShowing { focusBriefSearch = false }
        }
    }

    private func arrowButton(_ symbol: String, enabled: Bool, key: Character,
                             action: @escaping () -> Void) -> some View {
        BriefArrowButton(symbol: symbol, enabled: enabled, action: action)
            .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
    }

    // MARK: - Helpers

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

    private var briefsNewestFirst: [Brief] {
        appState.briefs.sorted { $0.createdAt > $1.createdAt }
    }

    private var currentIndex: Int? {
        guard let id = appState.selectedBriefID else { return nil }
        return briefsNewestFirst.firstIndex { $0.id == id }
    }

    private var canGoOlder: Bool {
        guard let idx = currentIndex else { return false }
        return idx + 1 < briefsNewestFirst.count
    }

    private var canGoNewer: Bool {
        guard let idx = currentIndex else { return false }
        return idx > 0
    }

    private var currentBriefLabel: String {
        guard let id = appState.selectedBriefID,
              let brief = appState.briefs.first(where: { $0.id == id })
        else { return "No digest" }
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

    private func navigate(offset: Int) {
        guard let idx = currentIndex else { return }
        let target = idx + offset
        guard target >= 0, target < briefsNewestFirst.count else { return }
        appState.selectedBriefID = briefsNewestFirst[target].id
    }
}

// MARK: - Chrome icon button

private struct ChromeIconButton: View {
    let symbol: String
    let active: Bool
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(active || isHovered ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Theme.controlRadius)
                        .fill(active ? Theme.surfaceHigh : (isHovered ? Theme.surface : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        // macOS does not expose .help() as the VoiceOver name, so label icon-only buttons explicitly.
        .accessibilityLabel(help)
        .animation(Theme.quick, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Brief arrow button

private struct BriefArrowButton: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isHovered && enabled ? Theme.textPrimary
                                 : (enabled ? Theme.textSecondary : Theme.textTertiary.opacity(0.35)))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: Theme.controlRadius)
                        .fill(isHovered && enabled ? Theme.surface : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(symbol == "chevron.left" ? "Older digest (⌘[)" : "Newer digest (⌘])")
        .accessibilityLabel(symbol == "chevron.left" ? "Older digest" : "Newer digest")
        .animation(Theme.quick, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Service status popover

private struct ServiceStatusPopover: View {
    let services: [String]
    let health: [String: AdapterHealthResult.Status]
    let lastChecked: Date?
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
                        }
                        .buttonStyle(.plain)
                        .help("Retry \(Theme.serviceName(service))")
                        .accessibilityLabel("Retry \(Theme.serviceName(service))")
                    }
                }
                .frame(height: 34)
                .padding(.horizontal, 14)
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
