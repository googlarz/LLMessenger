// LLMessenger/UI/Desk/DeskView.swift
//
// Persistent navigation rail: Act (primary) / Digests / Activity. Each selection
// drives the entire main content area (see ContentView) — the rail itself carries
// no content of its own, matching the Mail/Notes/Finder sidebar-selection pattern.

import SwiftUI

enum DeskLayout {
    case compact
    case regular

    var gutter: CGFloat {
        switch self {
        case .compact: return 18
        case .regular: return Theme.gutter
        }
    }
}

enum AppSection: String, CaseIterable {
    case act
    case digests
    case activity

    var label: String {
        switch self {
        case .act: return "Act"
        case .digests: return "Digests"
        case .activity: return "Activity"
        }
    }

    var icon: String {
        switch self {
        case .act: return "bolt.fill"
        case .digests: return "tray.full.fill"
        case .activity: return "clock.arrow.circlepath"
        }
    }

    var helpText: String {
        switch self {
        case .act: return "What needs you now."
        case .digests: return "What happened in your messages."
        case .activity: return "What changed or was sent."
        }
    }
}

struct DeskView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selectedTab: AppSection

    init(selectedTab: Binding<AppSection> = .constant(.act)) {
        self._selectedTab = selectedTab
    }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(AppSection.allCases, id: \.self) { section in
                DeskRailButton(
                    section: section,
                    isSelected: selectedTab == section,
                    badge: badge(for: section),
                    keyEquivalent: keyForSection(section)
                ) {
                    withAnimation(Theme.quick) { selectedTab = section }
                }
            }

            serviceFilterSection
                .padding(.top, 18)

            Spacer(minLength: 0)

            // Settings is a global destination, not something scoped to one
            // section — it belongs at the rail's own footer, always present,
            // not pinned inside the Digests archive column.
            Rule()
            SettingsButtonView()
                .padding(.top, 4)
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .onAppear { appState.refreshTasks() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }

    // MARK: - Service quick-filter

    /// One tap scopes the Act queue and the open digest to a single service.
    /// Uses counts the projection already computes — no configuration surface.
    private var serviceFilterSection: some View {
        VStack(spacing: 2) {
            HStack {
                WireLabel("Services")
                Spacer()
                if appState.serviceQuickFilter != nil {
                    Button("ALL") {
                        withAnimation(Theme.quick) { appState.serviceQuickFilter = nil }
                    }
                    .buttonStyle(.plain)
                    .font(Theme.mono(10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .help("Clear the service filter")
                    .accessibilityLabel("Show all services")
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)

            ForEach(["imessage", "signal", "telegram", "slack"], id: \.self) { service in
                ServiceFilterButton(
                    service: service,
                    // Activity is a global audit trail and deliberately doesn't
                    // honor this filter — showing it "selected" there implies a
                    // scoping that isn't actually happening on screen.
                    isSelected: selectedTab != .activity && appState.serviceQuickFilter == service,
                    count: actItemCount(for: service)
                ) {
                    withAnimation(Theme.quick) {
                        appState.serviceQuickFilter =
                            appState.serviceQuickFilter == service ? nil : service
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Service filter")
    }

    /// Items in the Act queue for this service — the number that matters here.
    private func actItemCount(for service: String) -> Int {
        appState.attentionProjection.actItems.filter { $0.service == service }.count
    }

    private func badge(for section: AppSection) -> String? {
        switch section {
        case .act:
            let count = appState.attentionProjection.actBadgeCount
            return count > 0 ? "\(count)" : nil
        case .digests:
            let cal = Calendar.current
            let todayCount = appState.briefs.filter { cal.isDateInToday($0.createdAt) }.count
            return todayCount > 0 ? "\(todayCount)" : nil
        case .activity:
            return nil
        }
    }

    private func keyForSection(_ section: AppSection) -> KeyEquivalent {
        switch section {
        case .act:      return "1"
        case .digests:  return "2"
        case .activity: return "3"
        }
    }
}

private struct ServiceFilterButton: View {
    let service: String
    let isSelected: Bool
    let count: Int
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                ServiceStamp(service: service, size: 15)
                Text(Theme.serviceName(service))
                    .font(Theme.sans(12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(textColor)
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)")
                        .font(Theme.mono(10, weight: .semibold))
                        .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .fill(isSelected ? Theme.surfaceHigh : (isHovered ? Theme.surfaceHigh.opacity(0.5) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(count == 0 && !isSelected ? 0.55 : 1)
        .help(isSelected
              ? "Show all services"
              : "Show only \(Theme.serviceName(service)) in Act and the open digest")
        .accessibilityLabel("\(Theme.serviceName(service)), \(count) item\(count == 1 ? "" : "s")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(isSelected ? "Clears the service filter" : "Filters to this service only")
        .animation(Theme.quick, value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var textColor: Color {
        isSelected ? Theme.textPrimary : (isHovered ? Theme.textSecondary : Theme.textTertiary)
    }
}

private struct DeskRailButton: View {
    let section: AppSection
    let isSelected: Bool
    let badge: String?          // nil = no badge; non-nil = numeric count shown
    let keyEquivalent: KeyEquivalent
    let onTap: () -> Void
    @State private var isHovered = false

    /// Vermilion is reserved for Act — items that need you now. Digests'
    /// "N today" is a plain count, not urgency, and reads as a tertiary numeral.
    private var isUrgent: Bool { section == .act }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(iconColor)
                Text(section.label)
                    .font(Theme.sans(12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(textColor)
                Spacer(minLength: 4)
                if let badge {
                    if isUrgent {
                        Text(badge)
                            .font(Theme.mono(10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(isSelected ? Theme.signal : Theme.signal.opacity(0.7))
                            )
                    } else {
                        Text(badge)
                            .font(Theme.mono(10, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .fill(isSelected ? Theme.surfaceHigh : (isHovered ? Theme.surfaceHigh.opacity(0.5) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(keyEquivalent, modifiers: .command)
        .help(section.helpText)
        .accessibilityHint(section.helpText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .animation(Theme.quick, value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var iconColor: Color {
        isSelected ? Theme.textPrimary : (isHovered ? Theme.textSecondary : Theme.textTertiary)
    }

    private var textColor: Color {
        isSelected ? Theme.textPrimary : (isHovered ? Theme.textSecondary : Theme.textTertiary)
    }
}

// MARK: - Demo transition banner

/// Shown for ~4 seconds while demo data is replaced by the first real sync.
struct DemoTransitionBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.7).frame(width: 14)
            Text("Getting your real messages…")
                .font(Theme.mono(10.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 8)
        .background(Theme.surface)
        .transition(.opacity)
    }
}

// The delegation kill switch moved to a fixed toolbar status item
// (MainToolbar.DelegationStatusItem) so it no longer reflows the content
// column as a banner whenever delegation is armed/disarmed.
