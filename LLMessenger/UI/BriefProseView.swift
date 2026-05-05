// LLMessenger/UI/BriefProseView.swift
import SwiftUI

// MARK: - Parsed JSON structures

struct BriefCard: Decodable {
    let service: String
    let conversation: String?
    let headline: String
    let priority: String
    let counts: Counts
    let summary: String
    let callback: String?
    let actions: [String]
    let quotes: [Quote]

    struct Counts: Decodable {
        let messages: Int
        let threads: Int
        let people: Int
    }

    struct Quote: Decodable {
        let from: String
        let time: String
        let text: String
    }
}

struct BriefJSON: Decodable {
    let total_messages: Int?
    let total_threads: Int?
    let total_people: Int?
    let cards: [BriefCard]
}

// MARK: - Inline service badge (iM / Tg / Sg)

struct SourceGlyphView: View {
    let service: String
    var size: CGFloat = 20

    var body: some View {
        Text(initial)
            .font(.system(size: size <= 18 ? 8.5 : 10, weight: .bold))
            .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.12))
            .frame(width: size, height: size)
            .background(Theme.serviceColor(service))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var initial: String {
        switch service {
        case "imessage": return "iM"
        case "telegram": return "Tg"
        case "signal":   return "Sg"
        default:         return String(service.prefix(2)).uppercased()
        }
    }
}

// MARK: - Source filter chips

struct SourceFilterView: View {
    let services: [String]
    let counts: [String: Int]
    @Binding var active: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(id: "all", label: "All sources", count: counts.values.reduce(0, +), color: nil)
                ForEach(services, id: \.self) { svc in
                    chip(id: svc, label: Theme.serviceName(svc),
                         count: counts[svc] ?? 0, color: Theme.serviceColor(svc))
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func chip(id: String, label: String, count: Int, color: Color?) -> some View {
        let sel = active == id
        Button { active = id } label: {
            HStack(spacing: 5) {
                if let color {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(sel ? Theme.textPrimary : Theme.textSecondary)
                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(sel ? Theme.surfaceHigh : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 999))
            .overlay(
                RoundedRectangle(cornerRadius: 999)
                    .stroke(sel ? Theme.border : Theme.border.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.12), value: sel)
    }
}

// MARK: - Priority pill

private struct PriorityPill: View {
    let priority: String

    var body: some View {
        Text("— \(label)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .tracking(0.4)
            .textCase(.uppercase)
    }

    private var label: String {
        switch priority {
        case "high": return "reply needed"
        case "med":  return "heads-up"
        default:     return "fyi"
        }
    }

    private var color: Color {
        switch priority {
        case "high": return Color(red: 0.95, green: 0.45, blue: 0.25)
        case "med":  return Color(red: 0.90, green: 0.72, blue: 0.30)
        default:     return Theme.textTertiary
        }
    }
}

// MARK: - Main prose view

struct BriefProseView: View {
    let brief: Brief
    let messages: [Message]
    @State private var filter: String = "all"

    private var parsedJSON: BriefJSON? {
        guard var summary = brief.openingSummary else { return nil }
        // Strip markdown code fences if the LLM wrapped the JSON
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
        Array(Set(messages.map(\.service))).sorted()
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

    private var visibleCards: [BriefCard]? {
        guard let json = parsedJSON else { return nil }
        return filter == "all" ? json.cards : json.cards.filter { $0.service == filter }
    }

    private var visibleMessages: [Message] {
        let sorted = messages.sorted { $0.timestamp < $1.timestamp }
        return filter == "all" ? sorted : sorted.filter { $0.service == filter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if services.count > 1 || (parsedJSON?.cards.count ?? 0) > 1 {
                SourceFilterView(
                    services: services,
                    counts: cardCounts,
                    active: $filter
                )
                .padding(.bottom, 12)
            }

            if let cards = visibleCards {
                cardsView(cards)
            } else {
                fallbackView
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - JSON card rendering

    @ViewBuilder
    private func cardsView(_ cards: [BriefCard]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(cards.enumerated()), id: \.offset) { idx, card in
                cardView(card)
                if idx < cards.count - 1 {
                    Divider()
                        .background(Theme.border.opacity(0.4))
                        .padding(.vertical, 16)
                        .padding(.horizontal, 28)
                }
            }

            if !cards.isEmpty {
                Text("Summaries are AI-generated and may miss nuance")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)
                    .padding(.bottom, 4)
                    .padding(.horizontal, 28)
            }
        }
    }

    @ViewBuilder
    private func cardView(_ card: BriefCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Service + headline + priority
            HStack(alignment: .center, spacing: 6) {
                SourceGlyphView(service: card.service, size: 22)
                Text(Theme.serviceName(card.service))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("—")
                    .foregroundStyle(Theme.textTertiary)
                Text(card.headline)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                PriorityPill(priority: card.priority)
            }
            .fixedSize(horizontal: false, vertical: true)

            // Metadata
            HStack(spacing: 4) {
                Text("\(card.counts.messages) message\(card.counts.messages == 1 ? "" : "s")")
                Text("·")
                Text("\(card.counts.threads) thread\(card.counts.threads == 1 ? "" : "s")")
                Text("·")
                Text("\(card.counts.people) \(card.counts.people == 1 ? "person" : "people")")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textTertiary)
            .monospacedDigit()

            // Summary prose
            Text(card.summary)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            // From earlier callback
            if let callback = card.callback, !callback.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Text("From earlier")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("—")
                        .foregroundStyle(Theme.accent)
                    Text(callback)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Quotes
            if !card.quotes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(card.quotes.enumerated()), id: \.offset) { _, quote in
                        HStack(alignment: .top, spacing: 8) {
                            Text(quote.time)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 36, alignment: .leading)
                                .padding(.top, 1)
                            SourceGlyphView(service: card.service, size: 16)
                                .padding(.top, 1)
                            (Text("\(quote.from): ").fontWeight(.semibold) + Text("\"\(quote.text)\"").italic())
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
                .padding(.leading, 2)
            }

            // Action items (NEXT)
            if !card.actions.isEmpty {
                HStack(spacing: 6) {
                    Text("NEXT")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .tracking(0.5)
                    ForEach(Array(card.actions.enumerated()), id: \.offset) { idx, action in
                        if idx > 0 {
                            Text("·")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Text(action)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .underline(pattern: .dash)
                    }
                }
            }
        }
        .padding(.horizontal, 28)
    }

    // MARK: - Fallback: grouped by service

    @ViewBuilder
    private var fallbackView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let summary = brief.openingSummary, !summary.isEmpty {
                summaryBlock(summary)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 22)
            }

            let grouped = Dictionary(grouping: visibleMessages, by: \.service)
            let sortedServices = grouped.keys.sorted()

            ForEach(Array(sortedServices.enumerated()), id: \.element) { idx, svc in
                if let msgs = grouped[svc] {
                    serviceGroup(service: svc, messages: msgs)
                    if idx < sortedServices.count - 1 {
                        Divider()
                            .background(Theme.border.opacity(0.4))
                            .padding(.vertical, 16)
                    }
                }
            }

            if !messages.isEmpty {
                Text("Summaries are AI-generated and may miss nuance")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 22)
                    .padding(.bottom, 4)
                    .padding(.horizontal, 28)
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
            .font(.system(size: 14.5))
            .foregroundStyle(Theme.textPrimary)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func serviceGroup(service: String, messages: [Message]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                SourceGlyphView(service: service)
                Text(Theme.serviceName(service))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text("·")
                    .foregroundStyle(Theme.textTertiary)
                Text("\(messages.count) message\(messages.count == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(messages, id: \.messageId) { msg in
                    quoteRow(msg)
                }
            }
            .padding(.leading, 14)
            .overlay(alignment: .leading) {
                Theme.serviceColor(service).opacity(0.45)
                    .frame(width: 2)
                    .clipShape(RoundedRectangle(cornerRadius: 1))
            }
        }
        .padding(.horizontal, 28)
    }

    @ViewBuilder
    private func quoteRow(_ msg: Message) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(timeStr(msg.timestamp))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 38, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(msg.sender)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text(msg.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary.opacity(0.78))
                    .italic()
                    .lineLimit(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func timeStr(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
