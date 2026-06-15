// LLMessenger/UI/BriefProseView.swift
//
// The brief body: a typeset digest. Cards are editorial entries separated by
// hairline rules, grouped under "NEEDS YOU" / "THE REST" section labels, with
// a mono filter line for sources. Card rendering lives in BriefCardView.

import Charts
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
    /// Decoded once per brief — six computed properties chain into this, and
    /// decoding the full brief JSON on every body evaluation cost ~8-10
    /// decodes per render (PERF-2026-06-12 #2).
    @State private var parsedCache: (briefID: Int64?, json: BriefJSON?) = (nil, nil)
    /// Conversation labels batch-fetched per brief — the per-card synchronous
    /// DB read in the stamp row ran on every hover (PERF-2026-06-12 #1).
    @State private var contextCache: [String: ConversationContext] = [:]

    struct TimelineTarget: Identifiable {
        let service: String
        let conversationId: String
        let displayName: String
        var id: String { "\(service)/\(conversationId)" }
    }

    // MARK: - Parsing

    /// Cached decode — returns the stored result when it matches this brief,
    /// otherwise decodes fresh (covers first render before onAppear fires).
    private var parsedJSON: BriefJSON? {
        if parsedCache.briefID == brief.id, parsedCache.briefID != nil {
            return parsedCache.json
        }
        return Self.decodeBriefJSON(brief)
    }

    private static func decodeBriefJSON(_ brief: Brief) -> BriefJSON? {
        // Shared lenient path with the engine (BriefJSON.decodeLenient) — tolerates fences,
        // prose, trailing commas, and truncation, and never diverges from the engine decoder.
        BriefJSON.decodeLenient(from: brief.openingSummary)
    }

    private func refreshCaches() {
        let json = Self.decodeBriefJSON(brief)
        parsedCache = (brief.id, json)
        var contexts: [String: ConversationContext] = [:]
        for card in json?.cards ?? [] {
            let key = "\(card.service)|\(card.conversationId)"
            if contexts[key] == nil,
               let ctx = appState.fetchConversationContext(service: card.service, conversationId: card.conversationId) {
                contexts[key] = ctx
            }
        }
        contextCache = contexts
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
        numberedVisibleCards.filter { $0.card.priority != "high" && !isNoise($0.card) }
    }

    private var noiseCards: [NumberedBriefCard] {
        numberedVisibleCards.filter { isNoise($0.card) }
    }

    /// A card folds into the noise strip if a saved context marked it low/noise
    /// (DigestOrdering.collapsed) OR the LLM itself rated it low priority. The
    /// latter is what folds automated senders (codes, receipts, tariff notices)
    /// that have no saved context — the common case.
    private func isNoise(_ card: BriefCard) -> Bool {
        // A high-priority card is never folded into the noise strip — otherwise it
        // would render in both "Needs you" and the FYI strip and be double-counted.
        card.priority != "high" && (card.collapsed || card.priority == "low")
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

            if let json = parsedJSON {
                WeekAtGlanceView(
                    messages: visibleMessages,
                    cards: numberedVisibleCards.map(\.card),
                    activeCount: highPriorityCards.count + otherCards.count,
                    needsYouCount: highPriorityCards.count
                )

                stillBrokenNotice

                if !highPriorityCards.isEmpty {
                    let total = numberedVisibleCards.count
                    let labelText = noiseCards.isEmpty
                        ? "Needs you"
                        : "Needs you · \(highPriorityCards.count) of \(total)"
                    sectionLabel(labelText, color: Theme.signal)
                    entries(highPriorityCards, startIndex: 0)
                }

                if !otherCards.isEmpty {
                    let otherLabel = highPriorityCards.isEmpty ? "This round" : "The rest"
                    sectionLabel(otherLabel, color: Theme.textTertiary)
                        .padding(.top, highPriorityCards.isEmpty ? 0 : 18)
                    // Promote the lead card to lede weight when there are no high-priority cards.
                    entries(otherCards, startIndex: highPriorityCards.count,
                            promotedCount: highPriorityCards.isEmpty ? 1 : 0)
                }

                if !noiseCards.isEmpty {
                    NoiseStripView(cards: noiseCards,
                                   startNumber: highPriorityCards.count + otherCards.count)
                        .padding(.top, (highPriorityCards.isEmpty && otherCards.isEmpty) ? 4 : 10)
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
        .onAppear {
            refreshCaches()
            withAnimation { appeared = true }
        }
        .onChange(of: brief.id) { _ in
            refreshCaches()
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
    /// Pass `promotedCount > 0` to render the first N cards expanded (lede weight).
    private func entries(_ cards: [NumberedBriefCard], startIndex: Int, promotedCount: Int = 0) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { idx, numbered in
                BriefCardView(
                    number: startIndex + idx + 1,
                    card: numbered.card,
                    briefID: brief.id,
                    conversationContext: contextCache["\(numbered.card.service)|\(numbered.card.conversationId)"],
                    onShowTimeline: { service, convId, name in
                        showingTimeline = TimelineTarget(service: service, conversationId: convId, displayName: name)
                    },
                    promoted: idx < promotedCount
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
            // Only render the summary as prose when it is NOT (malformed) JSON — otherwise the
            // user would see raw {"cards":…} braces. If JSON reached here it failed to decode,
            // so suppress it and fall through to the grouped messages below. (OpusPlus 2026-06-15)
            if let summary = brief.openingSummary, !summary.isEmpty, !BriefJSON.looksLikeJSON(summary) {
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

// MARK: - Noise strip

/// Folded FYI section: a single tappable line that expands to compact serif
/// one-liners. Cards with DigestOrdering.collapsed == true land here.
private struct NoiseStripView: View {
    let cards: [NumberedBriefCard]
    let startNumber: Int
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    WireLabel("FYI · \(cards.count) quiet item\(cards.count == 1 ? "" : "s")",
                              color: Theme.textTertiary)
                    Rule()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .animation(Theme.spring, value: expanded)
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("FYI, \(cards.count) quiet item\(cards.count == 1 ? "" : "s")")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Hides quiet items" : "Shows quiet items")

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { idx, numbered in
                        noiseRow(numbered, number: startNumber + idx + 1)
                        if numbered.id != cards.last?.id {
                            Rule().padding(.leading, Theme.gutter + 40)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Theme.spring, value: expanded)
    }

    private func noiseRow(_ numbered: NumberedBriefCard, number: Int) -> some View {
        let card = numbered.card
        let headline: String = {
            let h = card.headline
            let norm = h.trimmingCharacters(in: .whitespaces).lowercased()
            guard h.isEmpty || norm == "none" || norm == "none." else { return h }
            let s = String(card.summary.prefix(80))
            return s.isEmpty ? (card.conversation ?? Theme.serviceName(card.service)) : s
        }()
        return HStack(spacing: 8) {
            Text(String(format: "%02d", number))
                .font(Theme.mono(9.5, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 20, alignment: .leading)
            ServiceStamp(service: card.service, size: 14)
            Text(headline)
                .font(.system(size: 13, design: .serif))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if card.counts.messages > 1 {
                Text("\(card.counts.messages)M")
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 7)
    }
}

// MARK: - Week-at-a-glance pulse header

/// Seven-day message-volume histogram followed by an active-thread count.
/// Uses Swift Charts for proper accessibility, hit testing, and animation.
///
/// Two axes, intentionally distinct:
///   Left  — bar chart: message volume by day (answers "when was the week busy?")
///   Right — count readout: active card count  (answers "what needs attention?")
/// A hairline column rule separates them so readers don't conflate the two.
private struct WeekAtGlanceView: View {
    let messages: [Message]
    let cards: [BriefCard]
    let activeCount: Int
    let needsYouCount: Int

    @State private var appeared = false

    // MARK: Data

    private struct DayData: Identifiable {
        let id: Int            // 0 = today, 6 = oldest — used as ForEach key only
        let label: String      // "Mon", "Tue", … — unambiguous 3-letter abbreviations
        let count: Int
        let isToday: Bool
        let hasHighCard: Bool

        var barColor: Color {
            if hasHighCard { return Theme.signal }
            if isToday     { return Theme.textPrimary }
            if count > 0   { return Theme.textSecondary.opacity(0.5) }
            return Theme.border.opacity(0.6)
        }
    }

    private var dayData: [DayData] {
        let cal      = Calendar.current
        let today    = cal.startOfDay(for: Date())
        let highKeys = Set(
            cards.filter { $0.priority == "high" }
                 .map { "\($0.service)|\($0.conversationId)" }
        )
        let labels   = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]
        // Oldest day first → chart reads left-to-right in chronological order.
        return (0..<7).reversed().map { daysAgo -> DayData in
            let day     = cal.date(byAdding: .day, value: -daysAgo, to: today)!
            let nextDay = cal.date(byAdding: .day, value:  1,       to: day)!
            let dayMsgs = messages.filter { $0.timestamp >= day && $0.timestamp < nextDay }
            let hasHigh = dayMsgs.contains { highKeys.contains("\($0.service)|\($0.conversationId)") }
            let weekday = cal.component(.weekday, from: day)
            return DayData(id: daysAgo, label: labels[weekday - 1],
                           count: dayMsgs.count, isToday: daysAgo == 0, hasHighCard: hasHigh)
        }
    }

    /// Varies with actual message volume so the label carries information.
    private var weekCharacter: (text: String, color: Color) {
        let hasHigh = needsYouCount > 0
        if activeCount == 0 { return ("ALL QUIET",  Theme.textTertiary) }
        if hasHigh          { return ("NEEDS YOU",  Theme.signal) }
        // Count only the window the histogram actually shows, not lifetime messages.
        let total = dayData.reduce(0) { $0 + $1.count }
        if total > 100      { return ("HEAVY WEEK", Theme.standby) }
        if total > 40       { return ("BUSY WEEK",  Theme.textSecondary) }
        return                       ("LIGHT WEEK", Theme.textTertiary)
    }

    // MARK: Body

    var body: some View {
        let data       = dayData
        let character  = weekCharacter
        let totalCards = cards.count
        // The lead number must quantify what the character label names, or the pulse
        // contradicts the headline/section (e.g. "2 … NEEDS YOU" vs "1 needs you").
        let hasHigh    = needsYouCount > 0
        let leadCount  = hasHigh ? needsYouCount : activeCount

        HStack(alignment: .bottom, spacing: 0) {

            // Left: volume histogram
            Chart(data) { day in
                BarMark(
                    x: .value("Day", day.label),
                    y: .value("Messages", appeared ? day.count : 0)
                )
                .foregroundStyle(day.barColor)
                .cornerRadius(2, style: .continuous)
                .accessibilityLabel(Text(day.label))
                .accessibilityValue(
                    Text("\(day.count) message\(day.count == 1 ? "" : "s")"
                         + (day.hasHighCard ? ", high priority" : ""))
                )
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            // data is captured from the outer body scope.
                            // 7 consecutive days → each 3-letter label is unique.
                            let isToday = data.first(where: { $0.label == label })?.isToday ?? false
                            Text(label)
                                .font(Theme.mono(8, weight: isToday ? .semibold : .medium))
                                .foregroundStyle(isToday
                                    ? Theme.textSecondary
                                    : Theme.textTertiary.opacity(0.55))
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 52)
            .animation(.spring(response: 0.45, dampingFraction: 0.82), value: appeared)

            // Hairline column rule — visually separates volume from count
            Rectangle()
                .fill(Theme.border)
                .frame(width: Theme.hairline, height: 40)
                .padding(.horizontal, 16)

            // Right: active-thread count
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(leadCount)")
                        .font(Theme.display(20, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("OF \(totalCards)")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.bottom, 1)
                }
                Text(character.text)
                    .font(Theme.mono(9))
                    .tracking(0.8)
                    .foregroundStyle(character.color)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(leadCount) of \(totalCards) threads, \(character.text)")
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 12)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82).delay(0.1)) {
                appeared = true
            }
        }
    }
}
