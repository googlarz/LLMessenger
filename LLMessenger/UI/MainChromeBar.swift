import SwiftUI

/// Top chrome bar — the single zone that answers:
/// "Are my services working? Which brief am I on? How do I search?"
///
/// Replaces the old ContentHeaderBar (which only carried sidebar + media toggles).
/// Layout, left to right:
///   • Hamburger to reveal the full sidebar drawer (escape hatch for power users)
///   • Service-health chips (iM / Sg / Tg / Sk) with hover popover + Retry
///   • Brief picker pill: ◂ [Today 21:16 ▾] ▸  (popover lists recent briefs)
///   • Spacer
///   • Search button
///   • Media toggle (existing)
struct MainChromeBar: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel
    @Binding var sidebarCollapsed: Bool
    @Binding var showMedia: Bool
    @Binding var showSearch: Bool
    var onRetryService: ((String) -> Void)? = nil

    @State private var showingBriefPicker = false
    @State private var hoveredService: String? = nil

    var body: some View {
        ZStack {
            Theme.sidebar

            HStack(spacing: 8) {
                // Traffic-lights spacer
                Spacer().frame(width: 72)

                // Hamburger — escape hatch for users who want the full sidebar
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { sidebarCollapsed.toggle() }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(sidebarCollapsed ? Theme.textTertiary : Theme.textPrimary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Toggle sidebar")

                Divider().frame(height: 14).opacity(0.6)

                // Service health chips + last-checked line
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        ForEach(orderedServices, id: \.self) { svc in
                            ServiceHealthChip(
                                service: svc,
                                status: appState.serviceHealth[svc],
                                onRetry: { onRetryService?(svc) }
                            )
                        }
                    }
                    if let checked = appState.lastCheckedDate {
                        Text(lastCheckedLabel(from: checked))
                            .font(.system(size: 10))
                            .foregroundStyle(appState.hasServiceError ? Color.orange : Theme.textTertiary)
                    } else if appState.hasServiceError {
                        Text("⚠ Service error")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.orange)
                    }
                }

                // Brief picker — ◂ pill ▸
                briefPickerCluster

                Spacer()

                // Search
                Button {
                    showSearch.toggle()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(showSearch ? Theme.textPrimary : Theme.textTertiary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Search messages and briefs (⌘F)")
                .keyboardShortcut("f", modifiers: .command)

                // Media toggle (existing)
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { showMedia.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 11))
                        Text("Media")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(showMedia ? Theme.surfaceHigh : Color.clear)
                    .foregroundStyle(showMedia ? Theme.textPrimary : Theme.textTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(showMedia ? Theme.border : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .padding(.trailing, 14)
            }
        }
        .frame(height: 38)
    }

    // MARK: - Brief picker cluster

    private var briefPickerCluster: some View {
        HStack(spacing: 0) {
            // ◂ Previous brief (older)
            Button {
                navigate(offset: 1)  // older = later index in newest-first list
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(canGoOlder ? Theme.textSecondary : Theme.textTertiary.opacity(0.4))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoOlder)
            .keyboardShortcut("[", modifiers: .command)

            // Brief label pill
            Button {
                showingBriefPicker.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(currentBriefLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.surfaceHigh)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Theme.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingBriefPicker, arrowEdge: .bottom) {
                BriefListView()
                    .environmentObject(appState)
                    .environmentObject(chatViewModel)
                    .frame(width: 320, height: 460)
            }

            // ▸ Next brief (newer)
            Button {
                navigate(offset: -1)  // newer = earlier index in newest-first list
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(canGoNewer ? Theme.textSecondary : Theme.textTertiary.opacity(0.4))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoNewer)
            .keyboardShortcut("]", modifiers: .command)
        }
        .padding(.leading, 4)
    }

    // MARK: - Helpers

    private func lastCheckedLabel(from date: Date) -> String {
        if appState.hasServiceError { return "⚠ Service error" }
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "Checked just now" }
        return "Checked \(minutes) min ago"
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

// MARK: - Service health chip

private struct ServiceHealthChip: View {
    let service: String
    let status: AdapterHealthResult.Status?
    let onRetry: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onRetry) {
            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                Text(shortName)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(textColor)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(hovering ? Theme.surfaceHigh : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
    }

    private var shortName: String {
        switch service {
        case "imessage": return "iM"
        case "signal":   return "Sg"
        case "telegram": return "Tg"
        case "slack":    return "Sk"
        default:         return service.prefix(2).uppercased()
        }
    }

    private var dotColor: Color {
        guard let status else { return Color(nsColor: .tertiaryLabelColor) }
        switch status {
        case .ok:      return .green
        case .warning: return .orange
        case .error:   return .red
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
