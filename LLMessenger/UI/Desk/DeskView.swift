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
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .onAppear { appState.refreshTasks() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
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

private struct DeskRailButton: View {
    let section: AppSection
    let isSelected: Bool
    let badge: String?          // nil = no badge; non-nil = numeric count shown
    let keyEquivalent: KeyEquivalent
    let onTap: () -> Void
    @State private var isHovered = false

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
                    Text(badge)
                        .font(Theme.mono(10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(isSelected ? Theme.signal : Theme.signal.opacity(0.7))
                        )
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

// MARK: - Delegation kill switch banner

/// Always-visible safety bar when at least one conversation has auto-send delegation.
/// Lets the user pause all auto-sends in one tap without hunting through the menu bar.
struct DelegationKillSwitchBanner: View {
    @AppStorage(AgentDelegation.killSwitchKey) private var disabled = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(disabled ? Theme.textTertiary : Theme.standby)
                .frame(width: 6, height: 6)
            Text(disabled ? "Auto-send paused" : "Auto-send active")
                .font(Theme.mono(10.5, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(disabled ? Theme.textTertiary : Theme.textSecondary)
            Spacer(minLength: 0)
            Button(disabled ? "RESUME" : "PAUSE") { disabled.toggle() }
                .buttonStyle(WireActionStyle(tint: disabled ? Theme.standby : Theme.textSecondary))
                .accessibilityLabel(disabled ? "Resume auto-send for delegated lanes" : "Pause all delegated auto-sends")
                .accessibilityHint(disabled ? "Auto-send will resume for conversations where you enabled delegation." : "Stops delegated sends until you resume them.")
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 8)
        .background(disabled ? Color.clear : Theme.standby.opacity(0.06))
        .animation(Theme.quick, value: disabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(disabled ? "Auto-send paused" : "Auto-send active")
    }
}
