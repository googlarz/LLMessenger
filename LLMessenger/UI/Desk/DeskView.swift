// LLMessenger/UI/Desk/DeskView.swift
//
// Persistent left-panel sidebar: Inbox / Waiting / Activity.

import SwiftUI

struct DeskView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel
    @State private var selectedTab: DeskTab = .inbox

    enum DeskTab: String, CaseIterable {
        case inbox    = "Inbox"
        case waiting  = "Waiting"
        case activity = "Activity"
    }

    var body: some View {
        VStack(spacing: 0) {
            if appState.hasDelegatedLanes {
                DelegationKillSwitchBanner()
                Rule()
            }
            // Persistent across every tab + brief: your open commitments, tasks, and "maybe"s.
            ToDoStripView()

            tabBar
            Rule()

            Group {
                switch selectedTab {
                case .inbox:
                    InboxView()
                case .waiting:
                    OwedView()
                case .activity:
                    ActivityView()
                }
            }
            .id(selectedTab)
            .transition(.opacity)
        }
        // The strip is always on screen, so make sure its global incomplete-task list is loaded
        // even when the brief-archive drawer (which also refreshes it) is never opened.
        .onAppear { appState.refreshTasks() }
    }

    private var tabBar: some View {
        HStack(spacing: 12) {
            ForEach(DeskTab.allCases, id: \.self) { tab in
                DeskTabButton(
                    tab: tab,
                    isSelected: selectedTab == tab,
                    hasBadge: hasBadge(tab),
                    keyEquivalent: keyForTab(tab)
                ) {
                    withAnimation(Theme.quick) { selectedTab = tab }
                }
            }
            Spacer()
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 12)
        .padding(.bottom, 0)
        .background(Theme.sidebar)
    }

    private func hasBadge(_ tab: DeskTab) -> Bool {
        switch tab {
        case .inbox:
            return appState.nowNeedsAttention || appState.actionsReadyCount > 0
        case .waiting:
            return appState.owedCount > 0
        case .activity:
            return false
        }
    }

    private func keyForTab(_ tab: DeskTab) -> KeyEquivalent {
        switch tab {
        case .inbox:    return "1"
        case .waiting:  return "2"
        case .activity: return "3"
        }
    }
}

private struct DeskTabButton: View {
    let tab: DeskView.DeskTab
    let isSelected: Bool
    let hasBadge: Bool
    let keyEquivalent: KeyEquivalent
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    if hasBadge {
                        Circle()
                            .fill(isSelected ? Theme.signal : Theme.signal.opacity(0.6))
                            .frame(width: 5, height: 5)
                    }
                    Text(tab.rawValue.uppercased())
                        .font(Theme.mono(10.5, weight: .semibold))
                        .tracking(0.7)
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(isSelected ? Theme.textPrimary : (isHovered ? Theme.textSecondary : Theme.textTertiary))
                }
                .padding(.bottom, 8)

                (isSelected ? Theme.textPrimary : (isHovered ? Theme.textTertiary : Color.clear))
                    .frame(height: 1.5)
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(keyEquivalent, modifiers: .command)
        .animation(Theme.quick, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Delegation kill switch banner

/// Always-visible safety bar when at least one conversation has auto-send delegation.
/// Lets the user pause all auto-sends in one tap without hunting through the menu bar.
private struct DelegationKillSwitchBanner: View {
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
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 8)
        .background(disabled ? Color.clear : Theme.standby.opacity(0.06))
        .animation(Theme.quick, value: disabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(disabled ? "Auto-send paused. Tap to resume." : "Auto-send active. Tap to pause.")
    }
}
