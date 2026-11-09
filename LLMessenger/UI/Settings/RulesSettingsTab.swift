// LLMessenger/UI/Settings/RulesSettingsTab.swift
import SwiftUI
import GRDB

struct RulesSettingsTab: View {
    @State private var rules: [PriorityRule] = []
    @State private var editorTarget: RuleEditorTarget? = nil
    @State private var ruleToDelete: PriorityRule? = nil
    @State private var errorMessage: String? = nil
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
                        ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                            RuleRowView(
                                rule: rule,
                                position: index + 1,
                                canMoveUp: index > 0,
                                canMoveDown: index < rules.count - 1,
                                onMove: { offset in moveRule(rule, by: offset) },
                                onEdit: { editorTarget = .edit(rule) },
                                onDelete: { ruleToDelete = rule }
                            )
                            Rule()
                        }
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.signal)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }

                Button("Add Rule") { editorTarget = .new }
                    .buttonStyle(PaperButtonStyle())
                    .padding(.top, 12)

                Text(PriorityRuleCopy.precedenceNote)
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
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
        } message: {
            Text("The rule will be permanently removed. You can add it back at any time.")
        }
        .sheet(item: $editorTarget) { target in
            RuleEditorView(rule: target.rule) { rule in
                try await saveRule(rule)
            }
        }
    }

    private var store: PriorityRuleStore? { database.map(PriorityRuleStore.init) }

    private func loadRules() async {
        guard let store else { return }
        do {
            rules = try await store.loadAll()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load your rules: \(error.localizedDescription)"
        }
    }

    /// Throws so the editor sheet can stay open with the user's input when saving fails.
    private func saveRule(_ rule: PriorityRule) async throws {
        guard let store else { throw PriorityRuleError.unavailable }
        if rule.id == nil {
            try await store.add(rule)
        } else {
            try await store.update(rule)
        }
        await loadRules()
    }

    private func deleteRule(_ rule: PriorityRule) {
        guard let store, let id = rule.id else { return }
        Task {
            do {
                try await store.delete(id: id)
                await loadRules()
            } catch {
                errorMessage = "Couldn't delete that rule: \(error.localizedDescription) It is still in the list."
            }
        }
    }

    private func moveRule(_ rule: PriorityRule, by offset: Int) {
        guard let store, let id = rule.id else { return }
        Task {
            do {
                rules = try await store.move(id: id, by: offset)
                errorMessage = nil
            } catch {
                errorMessage = "Couldn't change the order: \(error.localizedDescription)"
                await loadRules()
            }
        }
    }
}

enum PriorityRuleError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Rules can't be saved right now." }
}

/// What the Add / Edit sheet is editing. `.new` has no rule yet.
enum RuleEditorTarget: Identifiable {
    case new
    case edit(PriorityRule)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let rule): return "edit-\(rule.id ?? -1)"
        }
    }

    var rule: PriorityRule? {
        if case .edit(let rule) = self { return rule }
        return nil
    }
}

// MARK: - Copy

enum PriorityRuleCopy {
    static let precedenceNote =
        "Rules run from top to bottom after the AI has read a message. The first rule that matches decides; the ones below it are ignored. Use the arrows to change the order."

    static let actionPrecedenceNote =
        "If you pick more than one action, Suppress wins over Always notify, and Always notify wins over a priority change."

    static let quietHoursApply =
        "While these hours are on, this rule is skipped and can't break through. Rules below it still apply."

    static let quietHoursNeedAlwaysNotify =
        "Quiet hours only affect rules set to Always notify. Turn on Always notify to use them."

    /// One line describing a rule, in evaluation terms.
    static func summary(for rule: PriorityRule) -> String {
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
        // Quiet hours only ever change an Always-notify rule, so only show them then.
        if rule.alwaysNotify, let qs = rule.quietStart, let qe = rule.quietEnd, !qs.isEmpty, !qe.isEmpty {
            parts.append("· skipped \(qs)–\(qe)")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Rule Row

private struct RuleRowView: View {
    let rule: PriorityRule
    let position: Int
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMove: (Int) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var deleteHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Text("\(position)")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 16, alignment: .trailing)
            Text(PriorityRuleCopy.summary(for: rule))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
                .foregroundStyle(canMoveUp ? Theme.textSecondary : Theme.textTertiary.opacity(0.4))
                .disabled(!canMoveUp)
                .help("Move up — checked earlier")
                .accessibilityLabel("Move rule \(position) up")
            Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .foregroundStyle(canMoveDown ? Theme.textSecondary : Theme.textTertiary.opacity(0.4))
                .disabled(!canMoveDown)
                .help("Move down — checked later")
                .accessibilityLabel("Move rule \(position) down")
            Button("Edit", action: onEdit)
                .buttonStyle(WireActionStyle())
                .accessibilityLabel("Edit rule \(position)")
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(deleteHovered ? Theme.signal : Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Delete rule")
            .accessibilityLabel("Delete rule \(position)")
            .animation(Theme.quick, value: deleteHovered)
            .onHover { deleteHovered = $0 }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Rule validation

enum RuleDraftValidation {
    static func hasCondition(contact: String, keyword: String, service: String) -> Bool {
        !contact.isEmpty || !keyword.isEmpty || service != "any"
    }

    /// A conditionless rule is valid — it matches "(any message)" — as long as it does something.
    static func canSave(contact: String, keyword: String, service: String,
                        setPriority: String, suppress: Bool, alwaysNotify: Bool) -> Bool {
        hasCondition(contact: contact, keyword: keyword, service: service)
            || !setPriority.isEmpty || suppress || alwaysNotify
    }

    /// Would silence every incoming message, urgent ones included.
    static func silencesEverything(contact: String, keyword: String, service: String, suppress: Bool) -> Bool {
        suppress && !hasCondition(contact: contact, keyword: keyword, service: service)
    }

    /// Quiet hours can only change an Always-notify rule.
    static func quietHoursApplicable(alwaysNotify: Bool) -> Bool { alwaysNotify }

    /// The quiet window to store: nil/nil unless Always notify is on and quiet hours are
    /// switched on, so a saved rule never carries hours that do nothing.
    static func quietWindow(alwaysNotify: Bool, enabled: Bool,
                            start: Date, end: Date) -> (start: String, end: String)? {
        guard alwaysNotify, enabled else { return nil }
        return (QuietHours.string(from: start), QuietHours.string(from: end))
    }

    /// Plain-words reason the quiet hours can't be saved, or nil.
    static func quietHoursProblem(alwaysNotify: Bool, enabled: Bool, start: Date, end: Date) -> String? {
        guard let window = quietWindow(alwaysNotify: alwaysNotify, enabled: enabled, start: start, end: end)
        else { return nil }
        return QuietHours.problem(start: window.start, end: window.end)
    }
}

// MARK: - Add / Edit Rule Sheet

struct RuleEditorView: View {
    let existing: PriorityRule?
    let onSave: (PriorityRule) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var contactPattern: String
    @State private var keywordPattern: String
    @State private var service: String
    @State private var setPriority: String
    @State private var suppress: Bool
    @State private var alwaysNotify: Bool
    @State private var quietEnabled: Bool
    @State private var quietStart: Date
    @State private var quietEnd: Date
    @State private var confirmSilenceEverything = false
    @State private var isSaving = false
    @State private var saveError: String? = nil

    private let priorityOptions = [("", "No change"), ("high", "High"), ("med", "Med"), ("low", "Low")]

    init(rule: PriorityRule?, onSave: @escaping (PriorityRule) async throws -> Void) {
        existing = rule
        self.onSave = onSave
        _contactPattern = State(initialValue: rule?.contactPattern ?? "")
        _keywordPattern = State(initialValue: rule?.keywordPattern ?? "")
        _service = State(initialValue: rule?.service ?? "any")
        _setPriority = State(initialValue: rule?.setPriority ?? "")
        _suppress = State(initialValue: rule?.suppress ?? false)
        _alwaysNotify = State(initialValue: rule?.alwaysNotify ?? false)
        let start = rule?.quietStart.flatMap(QuietHours.minutes(from:))
        let end = rule?.quietEnd.flatMap(QuietHours.minutes(from:))
        _quietEnabled = State(initialValue: (rule?.alwaysNotify ?? false) && start != nil && end != nil)
        _quietStart = State(initialValue: QuietHours.date(fromMinutes: start ?? 22 * 60))
        _quietEnd = State(initialValue: QuietHours.date(fromMinutes: end ?? 7 * 60))
    }

    private var quietProblem: String? {
        RuleDraftValidation.quietHoursProblem(alwaysNotify: alwaysNotify, enabled: quietEnabled,
                                              start: quietStart, end: quietEnd)
    }

    private var canSave: Bool {
        RuleDraftValidation.canSave(contact: contactPattern, keyword: keywordPattern, service: service,
                                    setPriority: setPriority, suppress: suppress, alwaysNotify: alwaysNotify)
            && quietProblem == nil && !isSaving
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WireLabel(existing == nil ? "New Rule" : "Edit Rule")
                .padding(.bottom, 14)

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
                    Text("WhatsApp").tag("whatsapp")
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
                Text(PriorityRuleCopy.actionPrecedenceNote)
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 14)

            Rule()

            quietHoursSection
                .padding(.vertical, 14)

            Rule()

            if let saveError {
                Text(saveError)
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.signal)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(PaperButtonStyle())
                Spacer()
                Button(existing == nil ? "Save Rule" : "Save Changes") {
                    if RuleDraftValidation.silencesEverything(
                        contact: contactPattern, keyword: keywordPattern, service: service, suppress: suppress
                    ) {
                        confirmSilenceEverything = true
                    } else {
                        save()
                    }
                }
                .disabled(!canSave)
                .buttonStyle(PaperButtonStyle(prominent: true))
                .confirmationDialog("Silence every message?", isPresented: $confirmSilenceEverything,
                                    titleVisibility: .visible) {
                    Button("Silence everything", role: .destructive) { save() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This rule has no conditions, so it suppresses notifications for every message on every service — urgent ones included.")
                }
            }
            .padding(.top, 14)
        }
        .frame(width: 400)
        .padding(22)
        .background(Theme.surface)
    }

    private var quietHoursSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            WireLabel("Quiet hours for \u{201C}Always notify\u{201D}")
            Toggle("Skip this rule during quiet hours", isOn: $quietEnabled)
                .font(Theme.sans(13))
                .toggleStyle(.switch)
                .tint(Theme.ok)
                .disabled(!alwaysNotify)
            HStack(spacing: 8) {
                Text("From")
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.textSecondary)
                DatePicker("From", selection: $quietStart, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Text("until")
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.textSecondary)
                DatePicker("Until", selection: $quietEnd, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Spacer()
            }
            .disabled(!alwaysNotify || !quietEnabled)
            .opacity(alwaysNotify && quietEnabled ? 1 : 0.5)
            if let quietProblem {
                Text(quietProblem)
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.signal)
            } else {
                Text(alwaysNotify ? PriorityRuleCopy.quietHoursApply : PriorityRuleCopy.quietHoursNeedAlwaysNotify)
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func save() {
        let window = RuleDraftValidation.quietWindow(alwaysNotify: alwaysNotify, enabled: quietEnabled,
                                                     start: quietStart, end: quietEnd)
        let rule = PriorityRule(
            id: existing?.id,
            contactPattern: contactPattern.isEmpty ? nil : contactPattern,
            keywordPattern: keywordPattern.isEmpty ? nil : keywordPattern,
            service: service == "any" ? nil : service,
            setPriority: setPriority.isEmpty ? nil : setPriority,
            suppress: suppress,
            alwaysNotify: alwaysNotify,
            sortOrder: existing?.sortOrder ?? 0,
            createdAt: existing?.createdAt ?? Date(),
            quietStart: window?.start,
            quietEnd: window?.end
        )
        isSaving = true
        saveError = nil
        Task {
            do {
                try await onSave(rule)
                dismiss()
            } catch {
                saveError = "Couldn't save this rule: \(error.localizedDescription) Your entries are still here — try again."
                isSaving = false
            }
        }
    }
}
