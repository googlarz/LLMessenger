// LLMessenger/UI/Settings/RulesSettingsTab.swift
import SwiftUI
import GRDB

struct RulesSettingsTab: View {
    @State private var rules: [PriorityRule] = []
    @State private var showingAddRule = false
    @State private var ruleToDelete: PriorityRule? = nil
    private let database: AppDatabase?

    init(database: AppDatabase? = nil) {
        self.database = database
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                WireLabel("Priority Rules")
                    .padding(.bottom, 10)

                if rules.isEmpty {
                    VStack(spacing: 6) {
                        Text("No rules yet")
                            .font(Theme.sans(13))
                            .foregroundStyle(Theme.textSecondary)
                        Text("Add a rule to override the AI's priority decisions for specific contacts or keywords.")
                            .font(Theme.sans(11))
                            .foregroundStyle(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    VStack(spacing: 0) {
                        ForEach(rules) { rule in
                            RuleRowView(rule: rule, onDelete: { ruleToDelete = rule })
                            Rule()
                        }
                    }
                }

                Button("Add Rule") { showingAddRule = true }
                    .buttonStyle(PaperButtonStyle())
                    .padding(.top, 12)

                Text("Rules are applied after AI analysis. First matching rule wins.")
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 14)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await loadRules() }
        .confirmationDialog("Delete this rule?", isPresented: Binding(
            get: { ruleToDelete != nil },
            set: { if !$0 { ruleToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let rule = ruleToDelete { deleteRule(rule) }
                ruleToDelete = nil
            }
            Button("Cancel", role: .cancel) { ruleToDelete = nil }
        }
        .sheet(isPresented: $showingAddRule) {
            AddRuleView { rule in
                saveRule(rule)
                showingAddRule = false
            }
        }
    }

    private func loadRules() async {
        guard let db = database else { return }
        do {
            rules = try await db.dbQueue.read { db in
                try PriorityRule.order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
            }
        } catch {
            // non-fatal: table may not exist yet in older DB
        }
    }

    private func saveRule(_ rule: PriorityRule) {
        guard let db = database else { return }
        Task {
            do {
                var r = rule
                try await db.dbQueue.write { db in try r.insert(db) }
                await loadRules()
            } catch {}
        }
    }

    private func deleteRule(_ rule: PriorityRule) {
        guard let db = database, let id = rule.id else { return }
        Task {
            do {
                try await db.dbQueue.write { db in
                    try PriorityRule.deleteOne(db, key: id)
                }
                await loadRules()
            } catch {}
        }
    }
}

// MARK: - Rule Row

private struct RuleRowView: View {
    let rule: PriorityRule
    let onDelete: () -> Void
    @State private var deleteHovered = false

    var body: some View {
        HStack {
            Text(ruleSummary)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(deleteHovered ? Theme.signal : Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Delete rule")
            .accessibilityLabel("Delete rule")
            .animation(Theme.quick, value: deleteHovered)
            .onHover { deleteHovered = $0 }
        }
        .padding(.vertical, 8)
    }

    private var ruleSummary: String {
        var parts: [String] = ["IF"]
        if let c = rule.contactPattern, !c.isEmpty { parts.append("contact contains \"\(c)\"") }
        if let k = rule.keywordPattern, !k.isEmpty {
            if parts.count > 1 { parts.append("AND") }
            parts.append("keyword contains \"\(k)\"")
        }
        if let s = rule.service, !s.isEmpty, s != "any" {
            if parts.count > 1 { parts.append("AND") }
            parts.append("service = \(s)")
        }
        if parts.count == 1 { parts.append("(any message)") }
        parts.append("→")
        if let p = rule.setPriority, !p.isEmpty { parts.append("priority: \(p)") }
        if rule.suppress { parts.append("suppress: yes") }
        if rule.alwaysNotify { parts.append("always notify") }
        if let qs = rule.quietStart, let qe = rule.quietEnd, !qs.isEmpty, !qe.isEmpty {
            parts.append("· quiet \(qs)–\(qe)")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Add Rule Sheet

private struct AddRuleView: View {
    let onSave: (PriorityRule) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var contactPattern = ""
    @State private var keywordPattern = ""
    @State private var service = "any"
    @State private var setPriority = ""
    @State private var suppress = false
    @State private var alwaysNotify = false
    @State private var quietStart = ""
    @State private var quietEnd = ""

    private let serviceOptions = ["any", "signal", "telegram", "imessage", "slack"]
    private let priorityOptions = [("", "No change"), ("high", "High"), ("med", "Med"), ("low", "Low")]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                WireLabel("Conditions")
                TextField("Contact name contains (optional)", text: $contactPattern)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.sans(13))
                TextField("Message contains (optional)", text: $keywordPattern)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.sans(13))
                Picker("Service", selection: $service) {
                    Text("Any").tag("any")
                    Text("Signal").tag("signal")
                    Text("Telegram").tag("telegram")
                    Text("iMessage").tag("imessage")
                    Text("Slack").tag("slack")
                }
                .font(Theme.sans(13))
            }
            .padding(.bottom, 14)

            Rule()

            VStack(alignment: .leading, spacing: 10) {
                WireLabel("Action")
                Picker("Set priority", selection: $setPriority) {
                    ForEach(priorityOptions, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
                .font(Theme.sans(13))
                Toggle("Suppress notification", isOn: $suppress)
                    .font(Theme.sans(13))
                    .toggleStyle(.switch)
                    .tint(Theme.ok)
                Toggle("Always notify", isOn: $alwaysNotify)
                    .font(Theme.sans(13))
                    .toggleStyle(.switch)
                    .tint(Theme.ok)
            }
            .padding(.vertical, 14)

            Rule()

            VStack(alignment: .leading, spacing: 10) {
                WireLabel("Quiet Hours (HH:mm, optional)")
                HStack(spacing: 8) {
                    TextField("From (e.g. 22:00)", text: $quietStart)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.sans(13))
                        .frame(maxWidth: .infinity)
                    Text("–")
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.textSecondary)
                    TextField("Until (e.g. 06:00)", text: $quietEnd)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.sans(13))
                        .frame(maxWidth: .infinity)
                }
                Text("During this window, \"Always notify\" is suppressed. \"Suppress\" rules remain active.")
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.vertical, 14)

            Rule()

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(PaperButtonStyle())
                Spacer()
                Button("Save Rule") { save() }
                    .disabled(contactPattern.isEmpty && keywordPattern.isEmpty && service == "any")
                    .buttonStyle(PaperButtonStyle(prominent: true))
            }
            .padding(.top, 14)
        }
        .frame(width: 400)
        .padding(22)
        .background(Theme.surface)
    }

    private func save() {
        let rule = PriorityRule(
            id: nil,
            contactPattern: contactPattern.isEmpty ? nil : contactPattern,
            keywordPattern: keywordPattern.isEmpty ? nil : keywordPattern,
            service: service == "any" ? nil : service,
            setPriority: setPriority.isEmpty ? nil : setPriority,
            suppress: suppress,
            alwaysNotify: alwaysNotify,
            sortOrder: 0,
            createdAt: Date(),
            quietStart: quietStart.isEmpty ? nil : quietStart,
            quietEnd: quietEnd.isEmpty ? nil : quietEnd
        )
        onSave(rule)
    }
}
