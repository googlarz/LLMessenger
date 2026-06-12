// LLMessengerWidget/LLMessengerWidget.swift
import WidgetKit
import SwiftUI

// MARK: - Shared types (mirrored from main app — keep in sync with WidgetDataProvider)

private struct BriefWidgetSnapshot: Codable {
    let headline: String
    let highCount: Int
    let medCount: Int
    let totalCards: Int
    let updatedAt: Date
    let briefID: Int64?
}

// MARK: - Timeline

private struct BriefEntry: TimelineEntry {
    let date: Date
    let snapshot: BriefWidgetSnapshot?
}

private struct Provider: TimelineProvider {
    static let appGroupID = "group.com.llmessenger.app"
    static let snapshotKey = "briefWidgetSnapshot"

    func placeholder(in context: Context) -> BriefEntry {
        BriefEntry(date: Date(), snapshot: BriefWidgetSnapshot(
            headline: "Meridian Series B — cap table review needed before 3pm",
            highCount: 2, medCount: 3, totalCards: 5,
            updatedAt: Date(), briefID: nil
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (BriefEntry) -> Void) {
        completion(BriefEntry(date: Date(), snapshot: loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BriefEntry>) -> Void) {
        let entry = BriefEntry(date: Date(), snapshot: loadSnapshot())
        // Refresh every 15 minutes; the main app also triggers a reload via Darwin notify.
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func loadSnapshot() -> BriefWidgetSnapshot? {
        // Try App Group UserDefaults first (available when signed with a team ID).
        if let defaults = UserDefaults(suiteName: Self.appGroupID),
           let data = defaults.data(forKey: Self.snapshotKey),
           let snapshot = try? JSONDecoder().decode(BriefWidgetSnapshot.self, from: data) {
            return snapshot
        }
        // Fallback: read from the JSON file the main app writes to Application Support.
        let fileURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("LLMessenger/widget-snapshot.json")
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(BriefWidgetSnapshot.self, from: data)
        else { return nil }
        return snapshot
    }
}

// MARK: - Views

private struct SmallWidgetView: View {
    let entry: BriefEntry

    var body: some View {
        if let snap = entry.snapshot, !isStale(snap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    // Wordmark
                    Text("LLM")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if snap.highCount > 0 {
                        Text("\(snap.highCount) high")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(red: 0.886, green: 0.310, blue: 0.196))
                    }
                }

                Spacer(minLength: 0)

                Text(snap.headline)
                    .font(.system(size: 12, weight: .medium, design: .serif))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                priorityLine(snap)
            }
            .padding(12)
        } else {
            emptyView
        }
    }

    private func priorityLine(_ snap: BriefWidgetSnapshot) -> some View {
        HStack(spacing: 6) {
            if snap.highCount > 0 {
                pill("\(snap.highCount)H", color: Color(red: 0.886, green: 0.310, blue: 0.196))
            }
            if snap.medCount > 0 {
                pill("\(snap.medCount)M", color: Color(red: 0.851, green: 0.647, blue: 0.302))
            }
            Spacer()
            Text(relativeTime(snap.updatedAt))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private func pill(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 0.5))
    }

    private var emptyView: some View {
        VStack(spacing: 6) {
            Text("LLMessenger")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("No brief yet")
                .font(.system(size: 11, design: .serif))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MediumWidgetView: View {
    let entry: BriefEntry

    var body: some View {
        if let snap = entry.snapshot, !isStale(snap) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("LLMessenger")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text(snap.headline)
                        .font(.system(size: 13, weight: .medium, design: .serif))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 0)

                    HStack(spacing: 6) {
                        if snap.highCount > 0 {
                            Text("\(snap.highCount) high")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color(red: 0.886, green: 0.310, blue: 0.196))
                        }
                        if snap.medCount > 0 {
                            Text("· \(snap.medCount) med")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text("· \(snap.totalCards) total")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Last updated")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(relativeTime(snap.updatedAt))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Link(destination: URL(string: "llmessenger://open")!) {
                        Text("Open Brief →")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.blue)
                    }
                }
                .frame(width: 90)
            }
            .padding(14)
        } else {
            VStack(spacing: 6) {
                Text("LLMessenger")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("Open the app to generate your first brief.")
                    .font(.system(size: 11, design: .serif))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }
}

// MARK: - Helpers

private func isStale(_ snap: BriefWidgetSnapshot) -> Bool {
    Date().timeIntervalSince(snap.updatedAt) > 12 * 3600
}

private func relativeTime(_ date: Date) -> String {
    let elapsed = Date().timeIntervalSince(date)
    if elapsed < 60 { return "just now" }
    if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
    if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
    return "\(Int(elapsed / 86400))d ago"
}

// MARK: - Widget

private struct LLMessengerWidgetEntryView: View {
    let entry: BriefEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .systemSmall {
            SmallWidgetView(entry: entry)
        } else {
            MediumWidgetView(entry: entry)
        }
    }
}

struct LLMessengerWidget: Widget {
    let kind = "com.llmessenger.app.widget.brief"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            LLMessengerWidgetEntryView(entry: entry)
                .containerBackground(.ultraThinMaterial, for: .widget)
        }
        .configurationDisplayName("LLMessenger Brief")
        .description("Your latest brief headline and priority counts.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Bundle

@main
struct LLMessengerWidgetBundle: WidgetBundle {
    var body: some Widget {
        LLMessengerWidget()
    }
}
