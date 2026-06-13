// LLMessenger/UI/Context/ContextEditor.swift
import SwiftUI
import GRDB

/// Editor for a single conversation's ConversationContext (v2 "Understand" fields).
/// Presented for a given service + conversationId. Loads any existing context on
/// appear and saves via repository.upsertConversationContext.
struct ContextEditor: View {
    let service: String
    let conversationId: String
    let conversationName: String
    let database: AppDatabase
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var relationship = ""
    @State private var priorityHint = "auto"
    @State private var importantTopics = ""
    @State private var noiseTopics = ""
    @State private var keySenders = ""
    @State private var aliases = ""
    @State private var contextNote = ""
    @State private var tone = ""
    @State private var responseExpectation = "none"
    @State private var privacyOverride = "none"
    @State private var autoAck = false
    @State private var autoRSVP = false

    private var repository: BriefRepository { BriefRepository(database: database) }

    private let priorityOptions = [("auto", "Auto"), ("high", "High"), ("med", "Med"), ("low", "Low")]
    private let responseOptions = [
        ("none", "Unspecified"), ("fast", "Reply fast"),
        ("evening ok", "Evening ok"), ("no reply needed", "No reply needed")
    ]
    private let privacyOptions = [
        ("none", "None"), ("local_only", "Local only"), ("never_draft", "Never draft")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                WireLabel("Context — \(conversationName)")
                    .padding(.bottom, 14)

                VStack(alignment: .leading, spacing: 10) {
                    WireLabel("Relationship")
                    TextField("e.g. son's basketball team", text: $relationship)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.sans(13))

                    WireLabel("Priority")
                    Picker("Priority", selection: $priorityHint) {
                        ForEach(priorityOptions, id: \.0) { value, label in Text(label).tag(value) }
                    }
                    .font(Theme.sans(13))
                }
                .padding(.bottom, 14)

                Rule()

                VStack(alignment: .leading, spacing: 10) {
                    WireLabel("Topics (comma-separated)")
                    TextField("Important: training, games", text: $importantTopics)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.sans(13))
                    TextField("Ignore: memes, polls", text: $noiseTopics)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.sans(13))
                    TextField("Key senders: Coach Lasse", text: $keySenders)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.sans(13))
                    TextField("Glossary: The Hall = home venue", text: $aliases)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.sans(13))
                }
                .padding(.vertical, 14)

                Rule()

                VStack(alignment: .leading, spacing: 10) {
                    WireLabel("Note")
                    TextEditor(text: $contextNote)
                        .font(Theme.sans(13))
                        .frame(height: 64)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.textTertiary.opacity(0.4)))
                }
                .padding(.vertical, 14)

                Rule()

                VStack(alignment: .leading, spacing: 10) {
                    WireLabel("Tone")
                    TextField("e.g. casual, lots of emoji", text: $tone)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.sans(13))
                }
                .padding(.vertical, 14)

                Rule()

                VStack(alignment: .leading, spacing: 10) {
                    WireLabel("Response expectation")
                    Picker("Response", selection: $responseExpectation) {
                        ForEach(responseOptions, id: \.0) { value, label in Text(label).tag(value) }
                    }
                    .font(Theme.sans(13))

                    WireLabel("Privacy")
                    Picker("Privacy", selection: $privacyOverride) {
                        ForEach(privacyOptions, id: \.0) { value, label in Text(label).tag(value) }
                    }
                    .font(Theme.sans(13))
                }
                .padding(.vertical, 14)

                Rule()

                VStack(alignment: .leading, spacing: 10) {
                    WireLabel("Delegation")
                    Text("LLMessenger will send these without asking — only for this conversation.")
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Auto-acknowledge (\u{201C}got it\u{201D} / \u{201C}thanks\u{201D})", isOn: $autoAck)
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.textPrimary)
                    Toggle("Auto-RSVP (yes / no to invites)", isOn: $autoRSVP)
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.textPrimary)
                }
                .padding(.vertical, 14)

                Rule()

                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(PaperButtonStyle())
                    Spacer()
                    Button("Save") { save() }
                        .buttonStyle(PaperButtonStyle(prominent: true))
                }
                .padding(.top, 14)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 420)
        .background(Theme.surface)
        .task { load() }
    }

    private func load() {
        guard let ctx = try? repository.fetchConversationContext(service: service, conversationId: conversationId)
        else { return }
        relationship = ctx.relationship ?? ""
        priorityHint = ctx.priorityHint
        importantTopics = ctx.importantTopicsList.joined(separator: ", ")
        noiseTopics = ctx.noiseTopicsList.joined(separator: ", ")
        keySenders = ctx.keySendersList.joined(separator: ", ")
        aliases = ctx.aliasesList.joined(separator: ", ")
        contextNote = ctx.contextNote ?? ""
        tone = ctx.tone ?? ""
        responseExpectation = ctx.responseExpectation ?? "none"
        privacyOverride = ctx.privacyOverride ?? "none"
        let delegated = ctx.delegationKinds
        autoAck = delegated.contains(AgentActionKind.ack.rawValue)
        autoRSVP = delegated.contains(AgentActionKind.rsvp.rawValue)
    }

    private func save() {
        let existing = try? repository.fetchConversationContext(service: service, conversationId: conversationId)
        var ctx = ConversationContext(
            service: service,
            conversationId: conversationId,
            label: existing?.label ?? "",
            priorityHint: priorityHint,
            updatedAt: Date(),
            relationship: relationship.isEmpty ? nil : relationship,
            contextNote: contextNote.isEmpty ? nil : contextNote,
            responseExpectation: responseExpectation == "none" ? nil : responseExpectation,
            privacyOverride: privacyOverride == "none" ? nil : privacyOverride,
            tone: tone.isEmpty ? nil : tone
        )
        ctx.importantTopicsList = splitCSV(importantTopics)
        ctx.noiseTopicsList = splitCSV(noiseTopics)
        ctx.keySendersList = splitCSV(keySenders)
        ctx.aliasesList = splitCSV(aliases)
        var delegated: [String] = []
        if autoAck { delegated.append(AgentActionKind.ack.rawValue) }
        if autoRSVP { delegated.append(AgentActionKind.rsvp.rawValue) }
        ctx.delegationKinds = delegated

        do {
            try repository.upsertConversationContext(ctx)
            onSaved()
            dismiss()
        } catch {
            // non-fatal; leave the sheet open so the user can retry
        }
    }

    private func splitCSV(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
