import SwiftUI

/// Top chrome bar — the single zone that answers:
/// "Are my services working? Which brief am I on? How do I search?"
///
/// Layout, left to right:
///   • Sidebar toggle (escape hatch for the full archive drawer)
///   • Service-health stamps (IM / SG / TG / SL) with status dot + Retry
///   • Brief picker: ◂ [TODAY 09:12 ▾] ▸  (popover lists the archive)
///   • Spacer
///   • Search · Media
struct MainChromeBar: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel
    @Binding var sidebarCollapsed: Bool
    @Binding var showMedia: Bool
    @Binding var showSearch: Bool
    /// Binding into ContentView — toggles the persistent Desk panel (Inbox/Waiting/Activity).
    var deskCollapsed: Binding<Bool>? = nil
    var onRetryService: ((String) -> Void)? = nil

    @State private var showingBriefPicker = false
    @State private var briefPickerHovered = false

    var body: some View {
        ZStack {
            Theme.sidebar

            HStack(spacing: 10) {
                // Traffic-lights spacer
                Spacer().frame(width: 70)

                chromeIcon("sidebar.left", active: !sidebarCollapsed, help: "Toggle archive (⌥⌘S)") {
                    withAnimation(Theme.spring) { sidebarCollapsed.toggle() }
                }

                if let deskCollapsed {
                    chromeIcon("sidebar.squares.left",
                               active: !deskCollapsed.wrappedValue,
                               help: "Toggle inbox panel") {
                        withAnimation(Theme.spring) { deskCollapsed.wrappedValue.toggle() }
                    }
                }

                Theme.border.frame(width: Theme.hairline, height: 14)

                // Service health stamps + last-checked line
                HStack(spacing: 4) {
                    ForEach(orderedServices, id: \.self) { svc in
                        ServiceHealthChip(
                            service: svc,
                            status: appState.serviceHealth[svc],
                            onRetry: { onRetryService?(svc) }
                        )
                    }
                }

                if let checked = appState.lastCheckedDate {
                    Text(lastCheckedLabel(from: checked).uppercased())
                        .font(Theme.mono(11))
                        .tracking(0.8)
                        .foregroundStyle(appState.hasServiceError ? Theme.standby : Theme.textTertiary)
                } else if appState.hasServiceError {
                    WireLabel("Service error", color: Theme.standby)
                }

                briefPickerCluster

                if DemoSeeder.isActive {
                    HStack(spacing: 6) {
                        Text("DEMO")
                            .font(Theme.mono(11, weight: .bold))
                            .tracking(1.1)
                            .foregroundStyle(Theme.standby)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(Theme.standby.opacity(0.55), lineWidth: 1)
                            )
                        Button("SET UP MY ACCOUNTS") { appState.onExitDemo?() }
                            .buttonStyle(WireActionStyle(tint: Theme.textPrimary))
                            .help("Clear the sample data and connect your real services")
                    }
                    .padding(.leading, 6)
                }

                Spacer()

                chromeIcon("magnifyingglass", active: showSearch, help: "Search messages and briefs (⌘F)") {
                    showSearch.toggle()
                }
                .keyboardShortcut("f", modifiers: .command)

                chromeIcon("photo.on.rectangle.angled", active: showMedia, help: "Media drawer") {
                    withAnimation(Theme.spring) { showMedia.toggle() }
                }
                .padding(.trailing, 14)
            }
        }
        .frame(height: 40)
    }

    private func chromeIcon(_ symbol: String, active: Bool, help: String,
                            action: @escaping () -> Void) -> some View {
        ChromeIconButton(symbol: symbol, active: active, help: help, action: action)
    }

    // MARK: - Brief picker cluster

    private var briefPickerCluster: some View {
        HStack(spacing: 0) {
            arrowButton("chevron.left", enabled: canGoOlder, key: "[") {
                navigate(offset: 1)  // older = later index in newest-first list
            }

            Button {
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
            .help("Browse the brief archive")
            .animation(Theme.quick, value: briefPickerHovered)
            .onHover { briefPickerHovered = $0 }
            .popover(isPresented: $showingBriefPicker, arrowEdge: .bottom) {
                BriefListView()
                    .environmentObject(appState)
                    .environmentObject(chatViewModel)
                    .frame(width: 320, height: 460)
            }

            arrowButton("chevron.right", enabled: canGoNewer, key: "]") {
                navigate(offset: -1)  // newer = earlier index in newest-first list
            }
        }
        .padding(.leading, 4)
    }

    private func arrowButton(_ symbol: String, enabled: Bool, key: Character,
                             action: @escaping () -> Void) -> some View {
        BriefArrowButton(symbol: symbol, enabled: enabled, action: action)
            .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
    }

    // MARK: - Helpers

    private func lastCheckedLabel(from date: Date) -> String {
        if appState.hasServiceError { return "Service error" }
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "Checked now" }
        return "Checked \(minutes)m ago"
    }

    private var orderedServices: [String] {
        ["imessage", "signal", "telegram", "slack"]
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
        else { return "No brief" }
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
        .accessibilityLabel(symbol == "chevron.left" ? "Older brief" : "Newer brief")
        .animation(Theme.quick, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Service health stamp

private struct ServiceHealthChip: View {
    let service: String
    let status: AdapterHealthResult.Status?
    let onRetry: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onRetry) {
            HStack(spacing: 4) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 5, height: 5)
                Text(shortName)
                    .font(Theme.mono(11, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(textColor)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(hovering ? Theme.surfaceHigh : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .animation(Theme.quick, value: hovering)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var shortName: String {
        switch service {
        case "imessage": return "IM"
        case "signal":   return "SG"
        case "telegram": return "TG"
        case "slack":    return "SL"
        default:         return service.prefix(2).uppercased()
        }
    }

    private var dotColor: Color {
        guard let status else { return Theme.textTertiary.opacity(0.4) }
        switch status {
        case .ok:      return Theme.ok
        case .warning: return Theme.standby
        case .error:   return Theme.signal
        }
    }

    private var textColor: Color {
        switch status {
        case .ok:      return Theme.textSecondary
        case .warning, .error: return Theme.textPrimary
        case nil:      return Theme.textTertiary
        }
    }

    private var helpText: String {
        let name = Theme.serviceName(service)
        switch status {
        case .ok:      return "\(name) — connected. Click to refresh."
        case .warning: return "\(name) — warning. Click to retry."
        case .error:   return "\(name) — error. Click to retry."
        case nil:      return "\(name) — not configured."
        }
    }
}
