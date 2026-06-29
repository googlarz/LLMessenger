// LLMessenger/UI/Desk/DeskView.swift
//
// Persistent left-panel sidebar: Act (primary) / Digest / Activity.
// Act is the default — it merges agent proposals + owed replies.
// Digest lists the brief archive. Activity shows the audit trail.

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

struct DeskView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel
    let layout: DeskLayout
    @State private var selectedTab: DeskTab = .act

    init(layout: DeskLayout = .regular) {
        self.layout = layout
    }

    enum DeskTab: String, CaseIterable {
        case act      = "Act"
        case digest   = "Digest"
        case activity = "Activity"
    }

    var body: some View {
        VStack(spacing: 0) {
            if appState.isDemoTransitioning {
                DemoTransitionBanner()
                Rule()
            } else if appState.hasDelegatedLanes {
                DelegationKillSwitchBanner()
                Rule()
            }
            // Persistent across every tab + brief: your open commitments, tasks, and "maybe"s.
            ToDoStripView(layout: layout)

            tabBar
            Rule()

            Group {
                switch selectedTab {
                case .act:
                    ActFeedView(layout: layout)
                case .digest:
                    BriefListView()
                case .activity:
                    ActivityView()
                }
            }
            .id(selectedTab)
            .transition(.opacity)
        }
        .onAppear { appState.refreshTasks() }
    }

    private var tabBar: some View {
        HStack(spacing: 12) {
            ForEach(DeskTab.allCases, id: \.self) { tab in
                DeskTabButton(
                    tab: tab,
                    isSelected: selectedTab == tab,
                    badge: badge(for: tab),
                    keyEquivalent: keyForTab(tab)
                ) {
                    withAnimation(Theme.quick) { selectedTab = tab }
                }
            }
            Spacer()
        }
        .padding(.horizontal, layout.gutter)
        .padding(.top, 12)
        .padding(.bottom, 0)
        .background(Theme.sidebar)
    }

    private func badge(for tab: DeskTab) -> String? {
        switch tab {
        case .act:
            let count = appState.actionsReadyCount + appState.owedCount
            return count > 0 ? "\(count)" : nil
        case .digest:
            let cal = Calendar.current
            let todayCount = appState.briefs.filter { cal.isDateInToday($0.createdAt) }.count
            return todayCount > 0 ? "\(todayCount)" : nil
        case .activity:
            return nil
        }
    }

    private func keyForTab(_ tab: DeskTab) -> KeyEquivalent {
        switch tab {
        case .act:      return "1"
        case .digest:   return "2"
        case .activity: return "3"
        }
    }
}

private struct DeskTabButton: View {
    let tab: DeskView.DeskTab
    let isSelected: Bool
    let badge: String?          // nil = no badge; non-nil = numeric count shown
    let keyEquivalent: KeyEquivalent
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    Text(tab.rawValue.uppercased())
                        .font(Theme.mono(10.5, weight: .semibold))
                        .tracking(0.7)
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(isSelected ? Theme.textPrimary : (isHovered ? Theme.textSecondary : Theme.textTertiary))

                    if let badge {
                        Text(badge)
                            .font(Theme.mono(9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(isSelected ? Theme.signal : Theme.signal.opacity(0.7))
                            )
                    }
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

// MARK: - Demo transition banner

/// Shown for ~4 seconds while demo data is replaced by the first real sync.
private struct DemoTransitionBanner: View {
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
