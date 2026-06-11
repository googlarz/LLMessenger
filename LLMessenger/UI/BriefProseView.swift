// LLMessenger/UI/BriefProseView.swift
//
// The brief body: a typeset digest. Cards are editorial entries separated by
// hairline rules, grouped under "NEEDS YOU" / "THE REST" section labels, with
// a mono filter line for sources. Card rendering lives in BriefCardView.

import SwiftUI

struct NumberedBriefCard: Identifiable {
    let number: Int
    let card: BriefCard

    var id: String { card.id }
}

struct BriefProseView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel
    let brief: Brief
    let messages: [Message]

    @State private var filter: String = "all"
    @State private var showingTimeline: TimelineTarget? = nil
    @State private var appeared = false

    struct TimelineTarget: Identifiable {
        let service: String
        let conversationId: String
        let displayName: String
        var id: String { "\(service)/\(conversationId)" }
    }

    // MARK: - Parsing

    private var parsedJSON: BriefJSON? {
        guard var summary = brief.openingSummary else { return nil }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            summary = trimmed
                .replacingOccurrences(of: #"^```[a-zA-Z]*\n?"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\n?```$"#, with: "", options: .regularExpression)
        }
        guard let data = summary.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BriefJSON.self, from: data)
    }

    private var services: [String] {
        if let json = parsedJSON, !json.cards.isEmpty {
            return Array(Set(json.cards.map(\.service))).sorted()
        }
        return Array(Set(messages.map(\.service))).sorted()
    }

    private var counts: [String: Int] {
        Dictionary(grouping: messages, by: \.service).mapValues(\.count)
    }

    private var cardCounts: [String: Int] {
        guard let json = parsedJSON else { return counts }
        return Dictionary(
            json.cards.map { ($0.service, $0.counts.messages) },
            uniquingKeysWith: +
        )
    }

    private var numberedVisibleCards: [NumberedBriefCard] {
        guard let json = parsedJSON else { return [] }
        return json.cards.enumerated().compactMap { index, card in
            guard filter == "all" || card.service == filter else { return nil }
            return NumberedBriefCard(number: index + 1, card: card)
        }
    }

    private var highPriorityCards: [NumberedBriefCard] {
        numberedVisibleCards.filter { $0.card.priority == "high" }
    }

    private var otherCards: [NumberedBriefCard] {
        numberedVisibleCards.filter { $0.card.priority != "high" }
    }

    private var visibleMessages: [Message] {
        let sorted = messages.sorted { $0.timestamp < $1.timestamp }
        return filter == "all" ? sorted : sorted.filter { $0.service == filter }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if services.count > 1 || (parsedJSON?.cards.count ?? 0) > 1 {
                filterLine
                    .padding(.horizontal, Theme.gutter)
                    .padding(.bottom, 14)
            }

            if parsedJSON != nil {
                stillBrokenNotice

                if !highPriorityCards.isEmpty {
                    sectionLabel("Priority", color: Theme.signal)
                    entries(highPriorityCards, startIndex: 0)
                }

                if !otherCards.isEmpty {
                    sectionLabel(highPriorityCards.isEmpty ? "This round" : "The rest",
                                 color: Theme.textTertiary)
                        .padding(.top, highPriorityCards.isEmpty ? 0 : 18)
                    entries(otherCards, startIndex: highPriorityCards.count)
                }

                markAllRow
            } else {
                fallbackView
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
        .sheet(item: $showingTimeline) { target in
            ConversationTimelineView(
                service: target.service,
                conversationId: target.conversationId,
                displayName: target.displayName,
                repository: appState.repository
            )
        }
        .onAppear { withAnimation { appeared = true } }
        .onChange(of: brief.id) { _ in
            appeared = false
            withAnimation { appeared = true }
        }
        // H key: file the first unhandled card visible in the current filter.
        .background {
            if let briefID = brief.id,
               let firstUnhandled = numberedVisibleCards.first(where: {
                   !appState.isCardHandled(briefID: briefID, cardID: $0.card.id)
               }) {
                Button("") {
                    appState.markCardHandled(briefID: briefID, cardID: firstUnhandled.card.id)
                }
                .keyboardShortcut("h", modifiers: [])
                .hidden()
            }
        }
    }

    // MARK: - Sections

    private func sectionLabel(_ text: String, color: Color) -> some View {
        HStack(spacing: 10) {
            WireLabel(text, color: color)
            Rule()
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 2)
    }

    /// Entries with hairline rules between them and a staggered fade-up on load.
    private func entries(_ cards: [NumberedBriefCard], startIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { idx, numbered in
                BriefCardView(
                    number: numbered.number,
                    card: numbered.card,
                    briefID: brief.id,
                    onShowTimeline: { service, convId, name in
                        showingTimeline = TimelineTarget(service: service, conversationId: convId, displayName: name)
                    }
                )
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(Theme.spring.delay(Double(startIndex + idx) * 0.045), value: appeared)

                if numbered.id != cards.last?.id {
                    Rule()
                        .padding(.leading, Theme.gutter)
                }
            }
        }
    }

    private var markAllRow: some View {
        Group {
            if let briefID = brief.id {
                let unhandledCount = numberedVisibleCards.filter { !appState.isCardHandled(briefID: briefID, cardID: $0.card.id) }.count
                if unhandledCount > 0 {
                    HStack {
                        Spacer()
                        Button("FILE ALL (\(unhandledCount))") {
                            withAnimation(Theme.quick) { appState.markAllHandled(briefID: briefID) }
                        }
                        .buttonStyle(WireActionStyle())
                        .help("Mark every card in this brief as handled")
                    }
                    .padding(.horizontal, Theme.gutter)
                    .padding(.top, 10)
                }
            }
        }
    }

    /// Warns only about services that are STILL unhealthy — a service that
    /// failed at brief time but is green now shouldn't scare anyone.
    @ViewBuilder
    private var stillBrokenNotice: some View {
        if let failedJSON = brief.failedServices,
           let data = failedJSON.data(using: .utf8),
           let allFailed = try? JSONDecoder().decode([String].self, from: data),
           !allFailed.isEmpty {
            let stillBroken = allFailed.filter { svc in
                let s = appState.serviceHealth[svc]
                return s != nil && s != .ok
            }
            if !stillBroken.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Theme.standby.frame(width: 2)
                        .clipShape(RoundedRectangle(cornerRadius: 1))
                    Text("\(stillBroken.map { Theme.serviceName($0) }.joined(separator: ", ")) is having connection trouble — its threads aren't in this brief.")
                        .font(Theme.sans(12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Filter line

    /// Mono filter line: ALL · IMESSAGE 4 · SIGNAL 12 — active gets paper
    /// text and an underline; no boxes, no capsules.
    private var filterLine: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                filterItem(id: "all", label: "All", count: cardCounts.values.reduce(0, +), color: nil)
                ForEach(services, id: \.self) { svc in
                    filterItem(id: svc, label: Theme.serviceName(svc),
                               count: cardCounts[svc] ?? 0, color: Theme.serviceColor(svc))
                }
            }
        }
    }

    private func filterItem(id: String, label: String, count: Int, color: Color?) -> some View {
        let selected = filter == id
        return Button {
            withAnimation(Theme.quick) { filter = id }
        } label: {
            HStack(spacing: 5) {
                if let color {
                    Circle().fill(color.opacity(selected ? 1 : 0.5)).frame(width: 5, height: 5)
                }
                Text(label.uppercased())
                    .font(Theme.mono(10, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                Text("\(count)")
                    .font(Theme.mono(10))
                    .foregroundStyle(selected ? Theme.textSecondary : Theme.textTertiary.opacity(0.7))
            }
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) {
                (selected ? Theme.textPrimary : Color.clear)
                    .frame(height: 1.5)
                    .offset(y: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Fallback: raw summary grouped by service

    @ViewBuilder
    private var fallbackView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let summary = brief.openingSummary, !summary.isEmpty {
                summaryBlock(summary)
                    .padding(.horizontal, Theme.gutter)
                    .padding(.bottom, 22)
            }

            let grouped = Dictionary(grouping: visibleMessages, by: \.service)
            let sortedServices = grouped.keys.sorted()

            ForEach(Array(sortedServices.enumerated()), id: \.element) { idx, svc in
                if let msgs = grouped[svc] {
                    serviceGroup(service: svc, messages: msgs)
                    if idx < sortedServices.count - 1 {
                        Rule()
                            .padding(.horizontal, Theme.gutter)
                            .padding(.vertical, 16)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func summaryBlock(_ text: String) -> some View {
        let attr = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)

        Text(attr)
            .font(Theme.bodyFont)
            .foregroundStyle(Theme.textPrimary)
            .lineSpacing(4.5)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func serviceGroup(service: String, messages: [Message]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ServiceStamp(service: service, size: 18)
                Text(Theme.serviceName(service).uppercased())
                    .font(Theme.mono(10.5, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(Theme.textSecondary)
                Text("\(messages.count) \(messages.count == 1 ? "MESSAGE" : "MESSAGES")")
                    .font(Theme.labelFont)
                    .tracking(Theme.labelTracking)
                    .foregroundStyle(Theme.textTertiary)
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(messages, id: \.messageId) { msg in
                    quoteRow(msg)
                }
            }
            .padding(.leading, 14)
            .overlay(alignment: .leading) {
                Theme.serviceColor(service).opacity(0.4)
                    .frame(width: Theme.hairline * 2)
            }
        }
        .padding(.horizontal, Theme.gutter)
    }

    @ViewBuilder
    private func quoteRow(_ msg: Message) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(timeStr(msg.timestamp))
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 36, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(msg.sender.uppercased())
                    .font(Theme.mono(9.5, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textSecondary)
                Text(msg.text)
                    .font(.system(size: 13, design: .serif))
                    .italic()
                    .foregroundStyle(Theme.textPrimary.opacity(0.8))
                    .lineLimit(5)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func timeStr(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
