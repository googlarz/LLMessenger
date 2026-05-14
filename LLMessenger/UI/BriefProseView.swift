// LLMessenger/UI/BriefProseView.swift
import SwiftUI

struct NumberedBriefCard: Identifiable {
    let number: Int
    let card: BriefCard

    var id: String { card.id }
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
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color)
                .textCase(.uppercase)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    private var label: String {
        switch priority {
        case "high": return "Action needed"
        case "med":  return "Heads-up"
        default:     return "FYI"
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

// MARK: - Evidence detail view

struct BriefCardEvidenceView: View {
    let card: BriefCard
    let briefID: Int64
    let repository: BriefRepository
    @State private var sources: [(source: BriefCardSource, message: Message?)] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isLoading {
                HStack {
                    ProgressView().scaleEffect(0.5)
                    Text("Loading evidence...")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.vertical, 4)
            } else {
                let items = sources
                if items.isEmpty {
                    Text("No direct evidence found in database.")
                        .font(.system(size: 12))
                        .italic()
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(item.message?.sender ?? "Unknown")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Theme.textSecondary)
                                Text(item.message.map { timeStr($0.timestamp) } ?? "")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textTertiary)
                                    .monospacedDigit()
                                Spacer()
                                Text(roleLabel(item.source.sourceRole))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.textTertiary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Theme.surfaceHigh)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                            
                            Text(item.message?.text ?? item.source.quoteText ?? "(No message text)")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textPrimary)
                                .lineSpacing(2)
                                .padding(.leading, 10)
                                .overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(item.source.sourceRole == "quote" ? Theme.accent : Theme.border)
                                        .frame(width: 2)
                                }
                        }
                    }
                }
            }
        }
        .padding(.top, 4)
        .onAppear {
            Task {
                do {
                    sources = try repository.fetchSourcesWithMessages(briefID: briefID, service: card.service, conversationID: card.conversationId)
                } catch {
                    print("Evidence error: \(error)")
                }
                isLoading = false
            }
        }
    }
    
    private func roleLabel(_ role: String) -> String {
        switch role {
        case "quote": return "DIRECT QUOTE"
        case "new_message": return "SUPPORTING"
        case "recent_context": return "CONTEXT"
        default: return role.uppercased().replacingOccurrences(of: "_", with: " ")
        }
    }

    private func timeStr(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

// MARK: - Main prose view

struct BriefProseView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel
    let brief: Brief
    let messages: [Message]
    @State private var filter: String = "all"
    @State private var expandedCards: Set<String> = []

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

            if let _ = parsedJSON {
                VStack(alignment: .leading, spacing: 0) {
                    if !highPriorityCards.isEmpty {
                        Text("ATTENTION NEEDED")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.25))
                            .tracking(0.8)
                            .padding(.horizontal, 28)
                            .padding(.bottom, 12)
                        
                        cardsView(highPriorityCards)
                            .padding(.bottom, 24)
                        
                        if !otherCards.isEmpty {
                            Divider()
                                .background(Theme.border.opacity(0.4))
                                .padding(.horizontal, 28)
                                .padding(.bottom, 24)
                        }
                    }
                    
                    if !otherCards.isEmpty {
                        if !highPriorityCards.isEmpty {
                            Text("FOR LATER")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.textTertiary)
                                .tracking(0.8)
                                .padding(.horizontal, 28)
                                .padding(.bottom, 12)
                        }
                        cardsView(otherCards)
                    }
                }
            } else {
                fallbackView
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - JSON card rendering

    @ViewBuilder
    private func cardsView(_ cards: [NumberedBriefCard]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { idx, card in
                cardView(card)
                if idx < cards.count - 1 && card.card.priority == "high" {
                    Divider()
                        .background(Theme.border.opacity(0.3))
                        .padding(.top, 4)
                        .padding(.horizontal, 28)
                }
            }
        }
    }

    @ViewBuilder
    private func cardView(_ numberedCard: NumberedBriefCard) -> some View {
        let card = numberedCard.card
        let isExpanded = expandedCards.contains(card.id)
        
        VStack(alignment: .leading, spacing: 10) {
            // Service + conversation + headline + priority
            HStack(alignment: .center, spacing: 6) {
                Text("#\(numberedCard.number)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.surfaceHigh)
                    .clipShape(Capsule())
                SourceGlyphView(service: card.service, size: 20)
                Text(card.conversation ?? Theme.serviceName(card.service))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                
                Spacer()
                
                PriorityPill(priority: card.priority)
            }

            Text(card.headline)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // Summary prose
            Text(card.summary)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            // From earlier callback
            if let callback = card.callback, !callback.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 3)
                    Text(callback)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }

            // Action items (NEXT)
            if !card.actions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(card.actions, id: \.self) { action in
                        HStack(spacing: 8) {
                            Image(systemName: "circle")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.accent)
                            Text(action)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // Trust / Evidence Toggle
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if isExpanded {
                        expandedCards.remove(card.id)
                    } else {
                        expandedCards.insert(card.id)
                        InstrumentationManager.shared.track(event: .sourceExpanded, metadata: ["cardID": card.id, "conversationID": card.conversationId])
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(isExpanded ? "Hide evidence" : "Show evidence (\(card.sourceMessageIds.count))")
                    if !card.quotes.isEmpty && !isExpanded {
                        Text("· \(card.quotes.count) quotes")
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            if isExpanded {
                BriefCardEvidenceView(card: card, briefID: brief.id ?? 0, repository: appState.repository)
                    .padding(.leading, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 8) {
                cardActionButton(
                    title: "More detail",
                    systemImage: "text.magnifyingglass"
                ) {
                    Task {
                        await chatViewModel.askForDetails(
                            service: card.service,
                            conversationID: card.conversationId,
                            displayName: card.conversation ?? "",
                            headline: card.headline
                        )
                    }
                }
                .help("Ask for more detail")

                cardActionButton(
                    title: "Reply",
                    systemImage: "arrowshape.turn.up.left"
                ) {
                    chatViewModel.prepareReply(
                        service: card.service,
                        conversationID: card.conversationId,
                        displayName: card.conversation ?? ""
                    )
                }
                .help("Draft a reply")

                Spacer(minLength: 0)
            }
            .padding(.top, 2)

            quickReplySection(card: card)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 8)
        .background(card.priority == "high" ? Theme.accent.opacity(0.03) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func cardActionButton(title: String,
                                  systemImage: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Theme.surfaceHigh.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.border.opacity(0.7), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Quick reply chips

    @ViewBuilder
    private func quickReplySection(card: BriefCard) -> some View {
        let isLoading = chatViewModel.quickRepliesLoading.contains(card.id)
        let replies = chatViewModel.quickReplies[card.id] ?? []

        if isLoading {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6)
                Text("Drafting replies…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.top, 2)
        } else if replies.isEmpty {
            // Show the trigger chip only on cards where a reply is likely needed.
            if card.priority == "high" || !card.actions.isEmpty {
                Button {
                    Task {
                        await chatViewModel.generateQuickReplies(
                            cardID: card.id,
                            service: card.service,
                            convId: card.conversationId,
                            convName: card.conversation ?? ""
                        )
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Quick reply")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Theme.accentMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.accent.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        } else {
            // Chips: label shown in the button, full draft revealed on hover and sent on confirm.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(replies) { reply in
                        Button {
                            chatViewModel.applyQuickReply(reply,
                                                          service: card.service,
                                                          convId: card.conversationId)
                        } label: {
                            Text(reply.label)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Theme.surfaceHigh)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().stroke(Theme.border, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(reply.draft)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .padding(.top, 2)
        }
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
