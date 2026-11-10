// LLMessenger/UI/Reply/ReplyComposer.swift
//
// The Reply composer is the ONLY place a person-directed message is written.
// Every reply entry point (Act rows, digest cards, the @ picker, commitments,
// an Ask-panel draft, Edit on an Act draft, a failed send) opens it with a
// ReplyComposerRequest. What is in its text area is exactly what will be sent;
// sending goes through AppState.sendFromComposer → stageManualApprove, the same
// 5-second undo path as Act.

import AppKit
import Foundation

/// Who a composer is addressed to, plus what to start with.
struct ReplyComposerRequest: Identifiable, Equatable {
    let id = UUID()
    let service: String
    let conversationId: String
    let conversationName: String
    var isGroup: Bool
    /// Text the editor starts with (a saved draft, an AI or agent draft, or "").
    var initialText: String
    /// Set when editing an existing Act action (a pending draft or a failed send):
    /// Send updates and stages THAT action instead of creating a new one.
    var sourceActionID: Int64? = nil
    /// Set for a follow-up on a commitment, so a completed send resolves it.
    var commitmentId: Int64? = nil

    static func == (lhs: ReplyComposerRequest, rhs: ReplyComposerRequest) -> Bool { lhs.id == rhs.id }

    var conversationKey: String { "\(service)|\(conversationId)" }
    var serviceName: String { Theme.serviceName(service) }
    var canSend: Bool { ServiceCapabilities.canSend(service: service) }

    /// "Anna · Signal" — the one-line answer to "who, where".
    var recipientLine: String { "\(displayName) · \(serviceName)" }

    var displayName: String {
        let name = conversationName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? conversationId : name
    }
}

/// What happened when the user pressed the composer's primary button.
enum ReplyComposerOutcome: Equatable {
    /// The send is staged behind the 5-second undo window.
    case staged(actionID: Int64)
    /// Read-only service: nothing was created; the text was handed to the user's app.
    case handedOff
    case empty
    case failed(String)
}

// MARK: - Composer model

/// Backs one open composer. `text` is exactly what Send hands to the send path.
@MainActor
final class ReplyComposerModel: ObservableObject {
    let request: ReplyComposerRequest
    @Published var text: String
    @Published private(set) var isDrafting = false
    @Published private(set) var draftError: String?
    /// The editor's text before the last AI draft replaced it, so it can be restored.
    @Published private(set) var textBeforeDraft: String?
    /// The last text the AI produced; the editor still holding it means "Redraft".
    private var lastAIDraft: String?
    @Published private(set) var sendError: String?
    let context: [Message]

    private let appState: AppState
    private var finished = false

    init(request: ReplyComposerRequest, appState: AppState) {
        self.request = request
        self.appState = appState
        self.text = request.initialText
        self.context = appState.composerContextMessages(service: request.service,
                                                        conversationId: request.conversationId)
    }

    var canSubmit: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isDrafting }

    var draftingBlockedReason: String? {
        ReplyDrafter(appState: appState).blockedReason(service: request.service,
                                                       conversationId: request.conversationId)
    }

    var draftButtonTitle: String {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Draft with AI" }
        return text == lastAIDraft ? "Redraft with AI" : "Replace with AI draft"
    }

    func draftWithAI() async {
        guard !isDrafting, draftingBlockedReason == nil else { return }
        isDrafting = true
        draftError = nil
        defer { isDrafting = false }
        do {
            let drafted = try await ReplyDrafter(appState: appState).draft(request: request, currentText: text)
            guard !drafted.isEmpty else {
                draftError = "The AI returned an empty draft. Try again or write it yourself."
                return
            }
            textBeforeDraft = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
            text = drafted
            lastAIDraft = drafted
        } catch let blocked as ReplyDrafter.Blocked {
            draftError = blocked.reason
        } catch {
            draftError = appState.friendly(error, source: .ai)
        }
    }

    func restoreTextBeforeDraft() {
        guard let previous = textBeforeDraft else { return }
        text = previous
        textBeforeDraft = nil
    }

    /// The primary button: Send (staged, undoable) or, for a read-only service,
    /// Copy and Open.
    @discardableResult
    func submit() -> ReplyComposerOutcome {
        guard canSubmit else { return .empty }
        let outcome = request.canSend
            ? appState.sendFromComposer(request, text: text)
            : appState.handOffReadOnlyReply(request, text: text)
        switch outcome {
        case .staged, .handedOff:
            finished = true
            sendError = nil
        case .failed(let message):
            sendError = message
        case .empty:
            break
        }
        return outcome
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        appState.closeReplyComposer(request, unsentText: text)
    }
}

// MARK: - Recipient facts

enum ConversationKind {
    /// Best-effort "is this a group chat". Contacts are authoritative when loaded;
    /// otherwise the services' own id conventions, then "more than one other sender".
    static func isGroup(service: String,
                        conversationId: String,
                        contacts: [Contact],
                        recentMessages: [Message]) -> Bool {
        for contact in contacts {
            if let handle = contact.handles.first(where: {
                $0.service == service && $0.conversationId == conversationId
            }) {
                return handle.isGroup
            }
        }
        switch service {
        case "whatsapp" where conversationId.hasSuffix("@g.us"):
            return true
        case "imessage" where conversationId.contains(";+;"):
            return true
        default:
            break
        }
        let senders = Set(recentMessages.filter { !$0.isSent }.map(\.sender))
        return senders.count > 1
    }
}

/// Opens the conversation in the service's own app. Moved from ReplyDraftView so
/// the composer's read-only path (WhatsApp) uses the same logic.
enum ServiceDeepLink {
    static func url(service: String, conversationId: String) -> URL? {
        switch service {
        case "telegram":
            return URL(string: "tg://")
        case "signal":
            return URL(string: "sgnl://")
        case "whatsapp":
            // 1:1 chats can be opened pre-addressed; groups and LID chats have no phone number.
            if let digits = WhatsAppAdapter.phoneDigits(fromJID: conversationId) {
                return URL(string: "whatsapp://send?phone=\(digits)")
            }
            return URL(string: "whatsapp://")
        case "imessage":
            // conversationID format from iMessage adapter: "any;-;+491234567890"
            if let range = conversationId.range(of: ";-;") {
                let recipient = String(conversationId[range.upperBound...])
                if !recipient.isEmpty,
                   let encoded = recipient.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                    return URL(string: "imessage://\(encoded)")
                }
            }
            return URL(string: "imessage://")
        default:
            return nil
        }
    }

    /// True when the link lands in the right chat, not just the app.
    static func opensExactChat(service: String, conversationId: String) -> Bool {
        switch service {
        case "whatsapp": return WhatsAppAdapter.phoneDigits(fromJID: conversationId) != nil
        default: return false
        }
    }
}

// MARK: - Drafting with AI

/// Fills the composer's text area using the app's reply-drafting prompt (the same
/// PromptBuilder .chat mode, voice sampling and privacy rules ChatViewModel uses).
/// It never sends and never writes to the database.
@MainActor
struct ReplyDrafter {
    let appState: AppState

    /// One plain line explaining why drafting is unavailable, or nil when allowed.
    /// Reads the conversation's privacy setting from the database, never the
    /// in-memory cache, so a just-changed setting can't be bypassed.
    func blockedReason(service: String, conversationId: String) -> String? {
        guard appState.isLLMConfigured else {
            return "AI drafting is off. Set up an AI provider in Settings → AI & Privacy to use it."
        }
        let ctx: ConversationContext?
        do {
            ctx = try appState.repository.fetchConversationContext(service: service, conversationId: conversationId)
        } catch {
            return "Couldn't read this conversation's privacy setting."
        }
        return Self.privacyBlock(context: ctx, clientIsCloud: appState.llmClient.isCloud)
    }

    /// The same rule digests and the agent use (BriefPromptAssembler.isExcludedByPrivacy).
    /// Global Local-only mode is enforced below this, by LLMGateway (egressBlocked).
    static func privacyBlock(context: ConversationContext?, clientIsCloud: Bool) -> String? {
        guard BriefPromptAssembler.isExcludedByPrivacy(context: context, clientIsCloud: clientIsCloud) else {
            return nil
        }
        return context?.privacyOverride == "never_draft"
            ? "AI drafting is off for this conversation."
            : "This conversation is Local-only and your AI provider is in the cloud."
    }

    struct Blocked: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Drafts (empty editor) or redrafts (editor has text) a reply.
    func draft(request: ReplyComposerRequest, currentText: String) async throws -> String {
        let service = request.service
        let convId = request.conversationId
        // Fail closed: the gate is checked here, on the context just read from
        // the database, immediately before any text leaves for the model.
        let ctx = try appState.repository.fetchConversationContext(service: service, conversationId: convId)
        if let reason = Self.privacyBlock(context: ctx, clientIsCloud: appState.llmClient.isCloud) {
            throw Blocked(reason: reason)
        }
        let recent = (try? appState.repository.fetchRecentContextMessages(
            service: service, conversationID: convId, before: Date().addingTimeInterval(1), limit: 20)) ?? []
        let contextText = recent.map { "[\(Theme.serviceName($0.service))] [\($0.sender)]: \($0.text)" }
            .joined(separator: "\n")

        let styleSince = Date().addingTimeInterval(-ReplyVoiceSampler.styleWindowDays * 24 * 3600)
        let recentAll = (try? appState.repository.fetchMessages(service: service, since: styleSince)) ?? []
        let sentTexts = ReplyVoiceSampler.sampleSentTexts(messages: recentAll, conversationId: convId)
        let styleBlock = ReplyVoiceSampler.styleBlock(sentTexts: sentTexts, tone: ctx?.tone)

        let systemPrompt = PromptBuilder.build(
            mode: .chat(conversations: ["\(Theme.serviceName(service)) — \(request.displayName)"]),
            basePrompt: appState.basePrompt,
            services: [service],
            // Summaries from other conversations can carry Local-only text: filtered for cloud clients.
            episodicSummaries: (try? appState.repository.recentEpisodicSummaries(
                service: service, limit: 3, clientIsCloud: appState.llmClient.isCloud)) ?? [],
            now: Date(),
            conversationContexts: [ctx].compactMap { $0 }
        )
        let base = contextText.isEmpty ? "(no prior messages)" : contextText
        let userBrief = styleBlock.isEmpty ? base : base + "\n\n" + styleBlock
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = trimmed.isEmpty
            ? "Write my reply to the latest message. Reply with only the message text."
            : "Rewrite this draft so it reads well, keeping my meaning and voice. Reply with only the message text:\n\(trimmed)"

        let response = try await appState.llmClient.complete(
            model: appState.llmModel,
            messages: [
                LLMMessage(role: .system, content: systemPrompt),
                LLMMessage(role: .user, content: userBrief),
                LLMMessage(role: .assistant, content: "I've read the conversation. What would you like to say?"),
                LLMMessage(role: .user, content: instruction)
            ],
            maxTokens: 400,
            purpose: .replyDraft,
            service: service,
            conversationId: convId
        )
        appState.recordDraftCreated()
        return ChatViewModel.stripDraftPrefix(response.text)
    }
}
