// LLMessenger/UI/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    var database: AppDatabase? = nil
    var onRunSetup: (() -> Void)? = nil
    var onBuild7DaySummaries: (() async -> Void)? = nil
    var onSyncContacts: (() async -> Void)? = nil
    var onRetryService: ((String) async -> Void)? = nil
    var onScheduleChanged: (() -> Void)? = nil

    @State private var selectedTab = 0

    private static let tabTitles = ["AI", "Services", "Privacy", "Instructions", "Rules", "Digest", "About"]

    var body: some View {
        VStack(spacing: 0) {
            // Wire tab bar: paper text + underline for the selected section,
            // margin-note gray for the rest. No filled pills.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 22) {
                    tabButtons
                    Spacer()
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        tabButtons
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            Rule()

            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .id(selectedTab)
        }
        // 720pt comfortably fits six wire tabs at the top — at 540pt the tab
        // content gets cramped, especially on the AI tab with three provider blocks.
        .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 560)
        .background(Theme.bg)
    }

    @ViewBuilder
    private var tabButtons: some View {
        ForEach(Array(Self.tabTitles.enumerated()), id: \.offset) { index, title in
            tabButton(index, title)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case 0:
            AISettingsTab(database: database)
        case 1:
            ServiceSettingsTab(database: database,
                               onBuild7DaySummaries: onBuild7DaySummaries,
                               onSyncContacts: onSyncContacts,
                               onRetryService: onRetryService)
        case 2:
            PrivacySettingsTab()
        case 3:
            InstructionsSettingsTab()
        case 4:
            RulesSettingsTab(database: database)
        case 5:
            DigestSettingsTab(onScheduleChanged: onScheduleChanged)
        default:
            AboutSettingsTab(database: database, onRunSetup: onRunSetup)
        }
    }

    private func tabButton(_ index: Int, _ title: String) -> some View {
        SettingsTabButton(index: index, title: title, selectedTab: $selectedTab)
    }
}

private struct SettingsTabButton: View {
    let index: Int
    let title: String
    @Binding var selectedTab: Int
    @State private var isHovered = false

    var body: some View {
        let isSelected = selectedTab == index
        Button {
            withAnimation(Theme.quick) { selectedTab = index }
        } label: {
            VStack(spacing: 6) {
                Text(title.uppercased())
                    .font(Theme.labelFont)
                    .tracking(Theme.labelTracking)
                    .foregroundStyle(
                        isSelected ? Theme.textPrimary
                        : isHovered ? Theme.textSecondary
                        : Theme.textTertiary
                    )
                (isSelected ? Theme.textPrimary : Color.clear)
                    .frame(height: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(title) settings")
        .accessibilityLabel("\(title) settings")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .animation(Theme.quick, value: isHovered)
        .onHover { isHovered = $0 }
    }
}
