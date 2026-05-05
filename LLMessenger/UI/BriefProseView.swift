// LLMessenger/UI/BriefProseView.swift
import SwiftUI

// MARK: - Inline service badge (iM / Tg / Sg)

struct SourceGlyphView: View {
    let service: String

    var body: some View {
        Text(initial)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Theme.serviceColor(service))
            .clipShape(RoundedRectangle(cornerRadius: 3))
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
                chip(id: "all", label: "All", count: counts.values.reduce(0, +), color: nil)
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

// MARK: - Main prose view

struct BriefProseView: View {
    let brief: Brief
    let messages: [Message]
    @State private var filter: String = "all"

    private var services: [String] {
        Array(Set(messages.map(\.service))).sorted()
    }

    private var counts: [String: Int] {
        Dictionary(grouping: messages, by: \.service).mapValues(\.count)
    }

    private var visible: [Message] {
        let sorted = messages.sorted { $0.timestamp < $1.timestamp }
        return filter == "all" ? sorted : sorted.filter { $0.service == filter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Filter chips — only shown when more than one service
            if services.count > 1 {
                SourceFilterView(services: services, counts: counts, active: $filter)
                    .padding(.bottom, 16)
            }

            VStack(alignment: .leading, spacing: 0) {
                // AI summary block
                if let summary = brief.openingSummary, !summary.isEmpty {
                    summaryBlock(summary)
                        .padding(.bottom, 22)
                }

                // Messages grouped by service, blockquote style
                let grouped = Dictionary(grouping: visible, by: \.service)
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

                // Footer
                if !messages.isEmpty {
                    Text("Summaries are AI-generated and may miss nuance")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 22)
                        .padding(.bottom, 4)
                }
            }
            .padding(.horizontal, 28)
        }
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Sub-views

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
            // Service header row
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

            // Blockquote messages
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
