// LLMessenger/UI/Desk/DeskView.swift
//
// Top-level three-altitude shell: Now / Today / Archive tabs.

import SwiftUI

struct DeskView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel
    @State private var selectedTab: DeskTab = .now

    enum DeskTab: String, CaseIterable {
        case now     = "Now"
        case owed    = "Owed"
        case today   = "Today"
        case archive = "Archive"
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Rule()

            switch selectedTab {
            case .now:
                NowView()
            case .owed:
                OwedView()
            case .today:
                TodayView()
            case .archive:
                BriefListView()
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(DeskTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.bg)
    }

    private func tabButton(_ tab: DeskTab) -> some View {
        Button {
            withAnimation(Theme.quick) { selectedTab = tab }
        } label: {
            HStack(spacing: 5) {
                if (tab == .now && appState.nowNeedsAttention) ||
                   (tab == .owed && appState.owedCount > 0) {
                    Circle()
                        .fill(Theme.signal)
                        .frame(width: 5, height: 5)
                }
                Text(tab.rawValue.uppercased())
                    .font(Theme.mono(10.5, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(selectedTab == tab ? Theme.textPrimary : Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .fill(selectedTab == tab ? Theme.surfaceHigh : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}
