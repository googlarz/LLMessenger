// LLMessenger/UI/ChatViewModel.swift
import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    private let recentContextWindow: TimeInterval = 24 * 3600
    private let maxDraftRecentContextMessages = 12
    @Published var threadItems: [ThreadItem] = []
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    @Published var inputFocusRequest = UUID()
    /// When set via the @ mention picker, the next send() bypasses the intent router
    /// and goes straight to draftReply with this target. Cleared after the draft is built.
    @Published var pendingTarget: MentionTarget?
    /// Keyed by BriefCard.id. Populated on-demand when the user taps "Quick reply" on a card.
    @Published var quickReplies: [String: [QuickReply]] = [:]
    /// Cards currently loading quick replies.
    @Published private(set) var quickRepliesLoading: Set<String> = []
    /// Cards where generation completed but the LLM returned unparseable output.
    @Published private(set) var quickRepliesFailed: Set<String> = []

    private let appState: AppState
    private var currentBrief: Brief?
    // Ordered distinct conversations in the loaded brief; built once per loadBrief().
    private(set) var briefConvs: [(service: String, convId: String, name: String)] = []

    private struct NaturalReplyRequest {
        let targetName: String
        let messageText: String
        let followUpText: String?
    }

    private enum IntentRoutingResult {
        case route(IntentRoute)
        case plainText(String)
    }

    struct MentionTarget: Equatable {
        let service: String
        let conversationId: String
        let displayName: String
        let isGroup: Bool
    }

    init(appState: AppState) {
        self.appState = appState
    }

    func loadBrief(_ brief: Brief) async throws {
        currentBrief = brief
        let messages = try appState.repository.fetchMessages(forBriefID: brief.id!)
        threadItems = messages.map { .message($0) }
        briefConvs = buildConvList(from: messages, brief: brief)
        quickReplies = [:]
        quickRepliesLoading = []
        quickRepliesFailed = []
    }

    // MARK: - Send

    func send() async {
        guard !isLoading else { return }
        let rawInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawInput.isEmpty else { return }
        inputText = ""
        await submit(rawInput)
    }

    func askForDetails(service: String,
                       conversationID: String,
                       displayName: String,
                       headline: String) async {
        guard let brief = currentBrief else { return }
        let title = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = title.isEmpty ? Theme.serviceName(service) : title
        // Build the question from trusted, app-controlled strings only and bypass
        // the intent router — external content (headline, displayName) must never
        // flow through routeIntents where it could be parsed as a routing instruction.
        let question = subject.isEmpty
            ? "Tell me more about \(label)."
            : "Tell me more about \(label): \(subject)"
        threadItems.append(.userMessage(id: UUID(), text: question))
        await answerQuestion(brief: brief, rawInput: question, echoUserMessage: false)
    }

    func prepareReply(service: String,
                      conversationID: String,
                      displayName: String) {
        let label = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = label.isEmpty ? conversationID : label
        inputText = "write to \(target): "
        inputFocusRequest = UUID()
    }

    /// Lock the next send() to a specific conversation. Used by the @ mention picker.
    func setMentionTarget(_ target: MentionTarget) {
        pendingTarget = target
        inputFocusRequest = UUID()
    }

    func clearMentionTarget() {
        pendingTarget = nil
    }

    private func submit(_ rawInput: String) async {
        guard !rawInput.isEmpty, let brief = currentBrief else { return }

        // Echo the user's message immediately, before any routing or LLM call.
        // Every downstream path used to append this itself; centralising it here
        // means the bubble shows up the instant Send is tapped, and routing/LLM
        // latency only delays the assistant's reply, not the user's own line.
        threadItems.append(.userMessage(id: UUID(), text: rawInput))

        // Case 0 — Explicit @ mention target: target is already known, skip intent routing
        // and go straight to the existing draft flow.
        if let target = pendingTarget {
            pendingTarget = nil
            await draftReply(brief: brief,
                             originalRequest: rawInput,
                             service: target.service,
                             convId: target.conversationId,
                             convName: target.displayName)
            return
        }

        // Case 1 — Picker resolution: user typed a number, service name, or
        // contact name to answer an active picker. Matching is case-insensitive
        // substring against displayName and the service's human name.
        if let picker = activePicker(),
           let chosen = resolvePickerChoice(rawInput, options: picker.options) {
            removePicker(id: picker.id)
            await draftReply(brief: brief,
                             originalRequest: picker.originalRequest,
                             service: chosen.service,
                             convId: chosen.convId,
                             convName: chosen.displayName)
            return
        }

        do {
            let context = interactionContext(for: brief)
            let routing = try await routeIntents(brief: brief, context: context, rawInput: rawInput)
            switch routing {
            case .route(let route):
                if await processIntentActions(route.actions, brief: brief, context: context, originalText: rawInput) {
                    return
                }
            case .plainText(let responseText):
                if await processLegacyShortcuts(brief: brief, rawInput: rawInput) {
                    return
                }
                processAssistantResponseText(responseText,
                                             originalRequest: rawInput,
                                             services: briefServices(for: brief))
                return
            }
        } catch {
            if await processLegacyShortcuts(brief: brief, rawInput: rawInput) {
                return
            }
            threadItems.append(.assistantResponse(id: UUID(),
                                                   text: "Error: \(error.localizedDescription)"))
            return
        }

        // Safety net: if the router returns valid JSON but no executable action, fall back.
        if await processLegacyShortcuts(brief: brief, rawInput: rawInput) {
            return
        }

        await answerQuestion(brief: brief, rawInput: rawInput, echoUserMessage: false)
    }

    private func routeIntents(brief: Brief,
                              context: ChatInteractionContext,
                              rawInput: String) async throws -> IntentRoutingResult {
        let services = briefServices(for: brief)
        let systemPrompt = PromptBuilder.build(
            mode: .intentRouter(context: context.routerPromptContext),
            basePrompt: appState.basePrompt,
            services: services,
            episodicSummaries: recentEpisodicContext(for: services, limitPerService: 2),
            now: Date()
        )

        let response = try await appState.llmClient.complete(
            model: appState.llmModel,
            messages: [
                LLMMessage(role: .system, content: systemPrompt),
                LLMMessage(role: .user, content: rawInput)
            ],
            maxTokens: 450
        )

        if let route = decodeIntentRoute(from: response.text) {
            return .route(route)
        }
        return .plainText(response.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func decodeIntentRoute(from text: String) -> IntentRoute? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            trimmed = trimmed
                .replacingOccurrences(of: #"^```[a-zA-Z]*\n?"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\n?```$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = trimmed.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(IntentRoute.self, from: data)
    }

    private func processIntentActions(_ actions: [IntentAction],
                                      brief: Brief,
                                      context: ChatInteractionContext,
                                      originalText: String) async -> Bool {
        let executableActions = actions.filter { action in
            action.type != .unknown
        }
        guard !executableActions.isEmpty else { return false }

        // The user message was already echoed at the top of submit(); don't re-append.

        for action in executableActions {
            switch action.type {
            case .draftReply:
                await processDraftIntent(action, brief: brief, context: context, originalText: originalText)
            case .answer:
                let question = normalized(action.question) ?? originalText
                await answerQuestion(brief: brief, rawInput: question, echoUserMessage: false)
            case .reviseDraft:
                await reviseDraft(action, brief: brief, context: context, originalText: originalText)
            case .sendDraftRequest:
                requestSendConfirmation(action, context: context)
            case .showSources:
                showSources(action, context: context)
            case .listActions, .findWaitingReplies, .summarizeChanges, .extractTasks, .compareConversations:
                let question = actionFocusedQuestion(for: action, originalText: originalText)
                await answerQuestion(brief: brief, rawInput: question, echoUserMessage: false)
            case .clarify:
                let text = normalized(action.question)
                    ?? normalized(action.instruction)
                    ?? "Which conversation or draft do you mean?"
                threadItems.append(.assistantResponse(id: UUID(), text: text))
            case .unknown:
                break
            }
        }

        return true
    }

    private func processDraftIntent(_ action: IntentAction,
                                    brief: Brief,
                                    context: ChatInteractionContext,
                                    originalText: String) async {
        // Prefer the user's own typed text over the LLM router's action.message field.
        // The router's message field is LLM-generated and must not be trusted as verbatim
        // user intent — it could carry injected instructions from external message content.
        let messageText = originalText

        if let conv = context.conversation(for: action) {
            await draftReply(brief: brief,
                             originalRequest: messageText,
                             service: conv.service,
                             convId: conv.convId,
                             convName: conv.name)
            return
        }

        let matches = normalized(action.targetName).map(context.conversations(matching:)) ?? []
        if matches.count > 1 {
            threadItems.append(.conversationPicker(id: UUID(),
                                                   originalRequest: messageText,
                                                   options: conversationOptions(from: matches)))
        } else {
            let target = normalized(action.targetName) ?? "that conversation"
            threadItems.append(.assistantResponse(id: UUID(),
                                                   text: "I couldn't find \(target) in this brief."))
        }
    }

    private func reviseDraft(_ action: IntentAction,
                             brief: Brief,
                             context: ChatInteractionContext,
                             originalText: String) async {
        guard let draftRef = context.draft(for: action) else {
            if context.drafts.isEmpty {
                threadItems.append(.assistantResponse(id: UUID(), text: "There are no drafts to revise."))
            } else {
                let list = context.drafts.map { "\($0.number). \($0.draft.conversationID)" }.joined(separator: "\n")
                threadItems.append(.assistantResponse(id: UUID(),
                    text: "Which draft do you want to revise? Reply with a number:\n\(list)"))
            }
            return
        }

        // Use the user's original text as the revision instruction when available.
        // Fall back to action fields only as a hint, capped at 300 chars and stripped
        // of control characters so LLM-generated content can't inject prompt directives.
        let rawInstruction = normalized(action.instruction)
            ?? normalized(action.message)
            ?? normalized(action.question)
        let instruction: String
        if let hint = rawInstruction {
            let sanitized = hint
                .unicodeScalars
                .filter { !CharacterSet.controlCharacters.contains($0) }
                .reduce(into: "") { $0.append(Character($1)) }
                .prefix(300)
            instruction = originalText + (sanitized.isEmpty ? "" : " (\(sanitized))")
        } else {
            instruction = originalText
        }
        isLoading = true
        defer { isLoading = false }

        let systemPrompt = PromptBuilder.build(
            mode: .chat(conversations: ["\(draftRef.draft.serviceID) — \(draftRef.draft.conversationID)"]),
            basePrompt: appState.basePrompt,
            services: [draftRef.draft.serviceID],
            episodicSummaries: recentEpisodicContext(for: [draftRef.draft.serviceID], limitPerService: 3),
            now: Date()
        )
        let messages = [
            LLMMessage(role: .system, content: systemPrompt),
            LLMMessage(role: .user, content: "Current draft:\n\(draftRef.draft.text)"),
            LLMMessage(role: .user, content: "Revise the draft. Instruction: \(instruction)")
        ]

        do {
            let response = try await appState.llmClient.complete(
                model: appState.llmModel,
                messages: messages,
                maxTokens: 400
            )
            let revised = stripDraftPrefix(response.text.trimmingCharacters(in: .whitespacesAndNewlines))
            updateDraft(id: draftRef.id, text: revised)
        } catch {
            threadItems.append(.assistantResponse(id: UUID(), text: "Error: \(error.localizedDescription)"))
        }
    }

    private func requestSendConfirmation(_ action: IntentAction, context: ChatInteractionContext) {
        guard let draftRef = context.draft(for: action) else {
            if context.drafts.isEmpty {
                threadItems.append(.assistantResponse(id: UUID(), text: "There are no drafts to send."))
            } else {
                let list = context.drafts.map { "\($0.number). \($0.draft.conversationID)" }.joined(separator: "\n")
                threadItems.append(.assistantResponse(id: UUID(),
                    text: "Which draft do you want to send? Reply with a number:\n\(list)"))
            }
            return
        }
        threadItems.append(.sendConfirmation(id: UUID(), draft: draftRef.draft))
    }

    private func showSources(_ action: IntentAction, context: ChatInteractionContext) {
        let sourceMessages: [Message]
        let title: String

        if let card = context.card(for: action) {
            sourceMessages = context.sourceMessages(for: card)
            title = "Here are the source messages for \(card.card.headline):"
        } else if let conversation = context.conversation(for: action) {
            sourceMessages = Array(context.conversationMessages(for: conversation).suffix(6))
            title = "Here are the recent messages from \(conversation.name):"
        } else {
            sourceMessages = Array(context.messages.suffix(6))
            title = "Here are the most relevant recent messages I can show from this brief:"
        }

        let sources = sourceMessages.map {
            ThreadSource(service: $0.service,
                         conversationID: $0.conversationId,
                         sender: $0.sender,
                         text: $0.text,
                         timestamp: $0.timestamp)
        }

        if sources.isEmpty {
            threadItems.append(.assistantResponse(id: UUID(), text: "I couldn't find source messages for that item."))
        } else {
            threadItems.append(.assistantResponseWithSources(id: UUID(), text: title, sources: sources))
        }
    }

    private func actionFocusedQuestion(for action: IntentAction, originalText: String) -> String {
        if let question = normalized(action.question) {
            return question
        }
        switch action.type {
        case .listActions:
            return "List the concrete actions I should take from this brief. Prioritize urgent replies and decisions."
        case .findWaitingReplies:
            return "Who appears to be waiting for a reply from me in this brief? Include why and suggested reply direction."
        case .summarizeChanges:
            return "What changed since the last brief or recent context? Focus on new information and changed decisions."
        case .extractTasks:
            return "Extract tasks, deadlines, promises, and follow-ups from this brief. Be concrete."
        case .compareConversations:
            return "Compare the referenced conversations and explain whether they are related."
        default:
            return originalText
        }
    }

    private func processLegacyShortcuts(brief: Brief, rawInput: String) async -> Bool {
        // The user message is echoed by submit() before this runs, so no path here
        // appends another userMessage — only branches that *do* something downstream
        // (a draft, a picker, a follow-up question) return true.
        if let request = extractNaturalReplyRequest(from: rawInput) {
            let matches = conversations(matching: request.targetName)
            if matches.count == 1 {
                let conv = matches[0]
                await draftReply(brief: brief,
                                 originalRequest: request.messageText,
                                 service: conv.service,
                                 convId: conv.convId,
                                 convName: conv.name)
                if let followUp = request.followUpText {
                    await answerQuestion(brief: brief, rawInput: followUp, echoUserMessage: false)
                }
                return true
            } else if matches.count > 1 {
                threadItems.append(.conversationPicker(id: UUID(),
                                                       originalRequest: request.messageText,
                                                       options: conversationOptions(from: matches)))
                if let followUp = request.followUpText {
                    await answerQuestion(brief: brief, rawInput: followUp, echoUserMessage: false)
                }
                return true
            }
        }

        if let (targetName, messageText) = extractNamedSend(from: rawInput) {
            let matches = conversations(matching: targetName)
            if matches.count == 1 {
                let conv = matches[0]
                await draftReply(brief: brief,
                                 originalRequest: messageText,
                                 service: conv.service,
                                 convId: conv.convId,
                                 convName: conv.name)
                return true
            } else if matches.count > 1 {
                threadItems.append(.conversationPicker(id: UUID(),
                                                       originalRequest: rawInput,
                                                       options: conversationOptions(from: matches)))
                return true
            }
        }

        return false
    }

    private func answerQuestion(brief: Brief, rawInput: String, echoUserMessage: Bool) async {
        let userMsgID = UUID()
        if echoUserMessage {
            threadItems.append(.userMessage(id: userMsgID, text: rawInput))
        }
        InstrumentationManager.shared.track(event: .followUpQuestionAsked, metadata: ["textLength": rawInput.count])
        isLoading = true
        defer { isLoading = false }

        do {
            let services = briefServices(for: brief)
            let recent: [(summary: String, createdAt: Date)] = services.flatMap {
                (try? appState.repository.recentEpisodicSummaries(service: $0, limit: 2)) ?? []
            }
            let convDescriptors = briefConvs.map { "\(Theme.serviceName($0.service)) — \($0.name)" }
            let systemPrompt = PromptBuilder.build(
                mode: .chat(conversations: convDescriptors),
                basePrompt: appState.basePrompt,
                services: services,
                episodicSummaries: recent,
                now: Date()
            )
            let llmMessages = buildLLMMessages(
                systemPrompt: systemPrompt,
                currentMsgID: userMsgID,
                currentText: rawInput
            )
            let response = try await appState.llmClient.complete(
                model: appState.llmModel,
                messages: llmMessages,
                maxTokens: 600
            )
            let responseText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)

            processAssistantResponseText(responseText,
                                         originalRequest: rawInput,
                                         services: services)
        } catch {
            threadItems.append(.assistantResponse(id: UUID(),
                                                   text: "Error: \(error.localizedDescription)"))
        }
    }

    private func processAssistantResponseText(_ responseText: String,
                                              originalRequest: String,
                                              services: [String]) {
        if responseText.uppercased().hasPrefix("CHOOSE") {
            threadItems.append(.conversationPicker(id: UUID(),
                                                   originalRequest: originalRequest,
                                                   options: conversationOptions(from: briefConvs)))
        } else if let draftRange = responseText.range(of: "DRAFT:", options: .caseInsensitive),
                  draftRange.lowerBound == responseText.startIndex {
            let rest = String(responseText[draftRange.upperBound...])
            var target = briefConvs.first
            var draftText = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            if let colonIdx = rest.firstIndex(of: ":") {
                let numStr = rest[rest.startIndex..<colonIdx]
                    .trimmingCharacters(in: .whitespaces)
                if let n = Int(numStr), n >= 1, n <= briefConvs.count {
                    target = briefConvs[n - 1]
                    draftText = String(rest[rest.index(after: colonIdx)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            let draft = ReplyDraft(id: UUID(),
                                   text: draftText,
                                   serviceID: target?.service ?? services.first ?? "",
                                   conversationID: target?.convId ?? "",
                                   senderName: "")
            threadItems.append(.replyDraft(id: draft.id, draft: draft))
        } else {
            threadItems.append(.assistantResponse(id: UUID(), text: responseText))
        }
    }

    // Called by ConversationPickerView buttons — skips the text input entirely.
    func selectPickerOption(pickerID: UUID, option: ConversationOption) async {
        guard let brief = currentBrief else { return }
        threadItems.append(.userMessage(id: UUID(), text: "\(option.number)"))
        removePicker(id: pickerID)
        await draftReply(brief: brief,
                         originalRequest: option.id.uuidString, // placeholder; resolved below
                         service: option.service,
                         convId: option.convId,
                         convName: option.displayName)
    }

    func selectPickerOption(pickerID: UUID, originalRequest: String, option: ConversationOption) async {
        guard let brief = currentBrief else { return }
        threadItems.append(.userMessage(id: UUID(), text: "\(option.number)"))
        removePicker(id: pickerID)
        await draftReply(brief: brief,
                         originalRequest: originalRequest,
                         service: option.service,
                         convId: option.convId,
                         convName: option.displayName)
    }

    func discardDraft(id: UUID) {
        threadItems.removeAll {
            if case .replyDraft(let i, _) = $0 { return i == id }
            return false
        }
    }

    func cancelSendConfirmation(id: UUID) {
        threadItems.removeAll {
            if case .sendConfirmation(let i, _) = $0 { return i == id }
            return false
        }
    }

    func confirmSendDraft(id: UUID) async {
        guard let confirmation = threadItems.compactMap({ item -> (UUID, ReplyDraft)? in
            if case .sendConfirmation(let confirmationID, let draft) = item {
                return (confirmationID, draft)
            }
            return nil
        }).first(where: { $0.0 == id }) else { return }

        let draft = confirmation.1
        guard let adapter = appState.adapters[draft.serviceID] else {
            threadItems.append(.assistantResponse(id: UUID(),
                                                   text: "I can't send this because \(Theme.serviceName(draft.serviceID)) is not connected."))
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            try await adapter.send(conversationID: draft.conversationID, text: draft.text)
            cancelSendConfirmation(id: id)
            discardDraft(id: draft.id)
            threadItems.append(.assistantResponse(id: UUID(), text: "Sent."))
        } catch {
            threadItems.append(.assistantResponse(id: UUID(),
                                                   text: "Error: \(error.localizedDescription)"))
        }
    }

    // MARK: - Quick replies

    /// Generates 3 style-matched reply options for a card on demand.
    /// The user's sent messages in that conversation are used as a style reference.
    func generateQuickReplies(cardID: String, service: String, convId: String, convName: String) async {
        guard currentBrief != nil else { return }
        guard !quickRepliesLoading.contains(cardID) else { return }

        quickRepliesLoading.insert(cardID)
        defer { quickRepliesLoading.remove(cardID) }

        let briefMessages = currentMessages()
        let convMessages = draftContextMessages(briefMessages: briefMessages,
                                                service: service,
                                                conversationID: convId)

        // Fetch recent sent messages in this conversation for style calibration.
        let styleSince = Date().addingTimeInterval(-14 * 24 * 3600)
        let recentAll = (try? appState.repository.fetchMessages(service: service, since: styleSince)) ?? []
        let sentMessages = recentAll
            .filter { $0.conversationId == convId && $0.isSent }
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(15)

        let conversationText = convMessages.suffix(20)
            .map { contextLine($0) }
            .joined(separator: "\n")
        let sentStyleText = sentMessages
            .map { $0.text }
            .joined(separator: "\n")

        let userContent = """
        Conversation (recent messages):
        \(conversationText.isEmpty ? "(no messages)" : conversationText)

        User's sent messages in this thread (style reference — match this voice exactly):
        \(sentStyleText.isEmpty ? "(no sent messages — use a neutral, casual register)" : sentStyleText)
        """

        // Pass empty basePrompt — the inbox assistant operating principles are irrelevant
        // here and add ~500 tokens of noise before the actual generation instructions.
        let systemPrompt = PromptBuilder.build(
            mode: .quickReplySuggester,
            basePrompt: "",
            services: [service],
            episodicSummaries: [],
            now: Date()
        )

        do {
            let response = try await appState.llmClient.complete(
                model: appState.llmModel,
                messages: [
                    LLMMessage(role: .system, content: systemPrompt),
                    LLMMessage(role: .user, content: userContent)
                ],
                maxTokens: 700
            )
            let replies = decodeQuickReplies(from: response.text)
            if replies.isEmpty {
                // LLM returned something but we couldn't parse it — surface a retry state.
                quickRepliesFailed.insert(cardID)
            } else {
                quickRepliesFailed.remove(cardID)
                quickReplies[cardID] = replies
            }
        } catch {
            quickRepliesFailed.insert(cardID)
            print("[QuickReply] Generation failed for card \(cardID): \(error)")
        }
    }

    /// Converts a quick reply option into a draft and appends it to the thread,
    /// then clears the chip list so the user can regenerate if needed.
    func applyQuickReply(_ reply: QuickReply, cardID: String, service: String, convId: String, convName: String) {
        let draft = ReplyDraft(id: UUID(),
                               text: reply.draft,
                               serviceID: service,
                               conversationID: convId,
                               senderName: convName)
        threadItems.append(.replyDraft(id: draft.id, draft: draft))
        // Clear chips so the "Quick reply" trigger reappears and the user
        // can generate a fresh set if they discard this draft.
        quickReplies.removeValue(forKey: cardID)
    }

    private func decodeQuickReplies(from text: String) -> [QuickReply] {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            trimmed = trimmed
                .replacingOccurrences(of: #"^```[a-zA-Z]*\n?"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\n?```$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = trimmed.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([QuickReply].self, from: data)) ?? []
    }

    // MARK: - Draft helper

    private func draftReply(brief: Brief,
                            originalRequest: String,
                            service: String,
                            convId: String,
                            convName: String) async {
        isLoading = true
        defer { isLoading = false }

        let briefMessages = threadItems.compactMap { item -> Message? in
            if case .message(let m) = item { return m } else { return nil }
        }
        let contextMessages = draftContextMessages(
            briefMessages: briefMessages,
            service: service,
            conversationID: convId
        )
        let briefText = contextMessages.map(contextLine).joined(separator: "\n")

        let systemPrompt = PromptBuilder.build(
            mode: .chat(conversations: ["\(Theme.serviceName(service)) — \(convName)"]),
            basePrompt: appState.basePrompt,
            services: [service],
            episodicSummaries: recentEpisodicContext(for: [service], limitPerService: 3),
            now: Date()
        )

        let llmMessages: [LLMMessage] = [
            LLMMessage(role: .system, content: systemPrompt),
            LLMMessage(role: .user, content: briefText.isEmpty ? "(no prior messages)" : briefText),
            LLMMessage(role: .assistant, content: "I've read the conversation. What would you like to say?"),
            LLMMessage(role: .user, content: originalRequest)
        ]

        do {
            let response = try await appState.llmClient.complete(
                model: appState.llmModel,
                messages: llmMessages,
                maxTokens: 400
            )
            let responseText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let draftText = stripDraftPrefix(responseText)
            let draft = ReplyDraft(id: UUID(), text: draftText,
                                   serviceID: service, conversationID: convId, senderName: "")
            threadItems.append(.replyDraft(id: draft.id, draft: draft))
            InstrumentationManager.shared.track(event: .draftCreated, metadata: ["service": service, "draftLength": draftText.count])
        } catch {
            threadItems.append(.assistantResponse(id: UUID(),
                                                   text: "Error: \(error.localizedDescription)"))
        }
    }

    // MARK: - Helpers

    private func buildLLMMessages(systemPrompt: String,
                                  currentMsgID: UUID,
                                  currentText: String) -> [LLMMessage] {
        let briefMessages = threadItems.compactMap { item -> Message? in
            if case .message(let m) = item { return m } else { return nil }
        }
        let briefText = briefMessages.suffix(60)
            .map { "[\(Theme.serviceName($0.service))] \($0.sender): \($0.text)" }
            .joined(separator: "\n")

        var msgs: [LLMMessage] = [
            LLMMessage(role: .system, content: systemPrompt),
            LLMMessage(role: .user, content: briefText.isEmpty ? "(no messages)" : briefText),
            LLMMessage(role: .assistant, content: "Got it. What would you like to know or do?")
        ]
        // Replay prior chat turns (exclude brief messages and current user message).
        for item in threadItems {
            switch item {
            case .userMessage(let id, let text) where id != currentMsgID:
                msgs.append(LLMMessage(role: .user, content: text))
            case .assistantResponse(_, let text):
                msgs.append(LLMMessage(role: .assistant, content: text))
            case .assistantResponseWithSources(_, let text, let sources):
                let sourceText = sources.map { "\($0.sender): \($0.text)" }.joined(separator: "\n")
                msgs.append(LLMMessage(role: .assistant, content: "\(text)\n\(sourceText)"))
            case .replyDraft(_, let draft):
                msgs.append(LLMMessage(role: .assistant, content: "DRAFT: \(draft.text)"))
            case .sendConfirmation(_, let draft):
                msgs.append(LLMMessage(role: .assistant, content: "SEND CONFIRMATION PENDING: \(draft.text)"))
            default:
                break
            }
        }
        msgs.append(LLMMessage(role: .user, content: currentText))
        return msgs
    }

    private func draftContextMessages(briefMessages: [Message],
                                      service: String,
                                      conversationID: String) -> [Message] {
        let convMessages = briefMessages.filter { $0.service == service && $0.conversationId == conversationID }
        guard !convMessages.isEmpty else {
            return Array(briefMessages.suffix(30))
        }

        let recentContext = fetchRecentDraftContext(
            service: service,
            conversationID: conversationID,
            before: convMessages[0].timestamp
        )
        return Array((recentContext + convMessages).suffix(30))
    }

    private func fetchRecentDraftContext(service: String,
                                         conversationID: String,
                                         before date: Date) -> [Message] {
        (try? appState.repository.fetchRecentContextMessages(
            service: service,
            conversationID: conversationID,
            before: date,
            since: date.addingTimeInterval(-recentContextWindow),
            limit: maxDraftRecentContextMessages
        )) ?? []
    }

    private func recentEpisodicContext(for services: [String], limitPerService: Int) -> [(summary: String, createdAt: Date)] {
        var merged: [(summary: String, createdAt: Date)] = []
        var seen = Set<String>()

        for service in services {
            let entries = (try? appState.repository.recentEpisodicSummaries(service: service, limit: limitPerService)) ?? []
            for entry in entries {
                let key = "\(service)|\(entry.createdAt.timeIntervalSince1970)|\(entry.summary)"
                if seen.insert(key).inserted {
                    merged.append(entry)
                }
            }
        }

        return merged.sorted { $0.createdAt > $1.createdAt }
    }

    private func contextLine(_ message: Message) -> String {
        let serviceName = Theme.serviceName(message.service)
        return "[\(serviceName)] [\(message.sender)]: \(message.text)"
    }

    private func interactionContext(for brief: Brief) -> ChatInteractionContext {
        ChatInteractionContext(brief: brief,
                               messages: currentMessages(),
                               threadItems: threadItems,
                               conversationTuples: briefConvs)
    }

    private func currentMessages() -> [Message] {
        threadItems.compactMap { item -> Message? in
            if case .message(let m) = item { return m }
            return nil
        }
    }

    private func updateDraft(id: UUID, text: String) {
        threadItems = threadItems.map { item in
            if case .replyDraft(let draftID, var draft) = item, draftID == id {
                draft.text = text
                return .replyDraft(id: draftID, draft: draft)
            }
            return item
        }
    }

    private func stripDraftPrefix(_ responseText: String) -> String {
        var text = responseText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip "DRAFT:" / "Reply:" / "Message:" / "Response:" leaders, case-insensitive.
        for keyword in ["DRAFT:", "Reply:", "Message:", "Response:", "Here's the reply:", "Here's a draft:"] {
            if let range = text.range(of: keyword, options: [.caseInsensitive, .anchored]) {
                text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Strip a leading "1:" / "1." / "1)" pattern — when the user picks option 1
        // from a numbered conversation picker, the LLM sometimes copies that style
        // into the draft body. Only matches single- or two-digit leaders to avoid
        // damaging legitimate content like "2025-…".
        if let regex = try? NSRegularExpression(pattern: #"^\d{1,2}\s*[:.\)]\s*"#) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip surrounding straight or smart quotes so the body sends cleanly.
        let quoteChars: [Character] = ["\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}"]
        if let first = text.first, quoteChars.contains(first),
           let last = text.last, quoteChars.contains(last), text.count > 1 {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return text
    }

    private func buildConvList(from messages: [Message],
                               brief: Brief) -> [(service: String, convId: String, name: String)] {
        // Collect the best display name for each conversation — first non-nil conversationName
        // wins. Using only the first-seen message would lock in nil if early messages (e.g.
        // sent messages from before the adapter stored names) lack a display name, even though
        // later messages in the same conversation have the human-readable name.
        var nameByKey: [String: String] = [:]
        var order: [String] = []
        var convByKey: [String: (service: String, convId: String)] = [:]

        for m in messages {
            let key = "\(m.service):\(m.conversationId)"
            if convByKey[key] == nil {
                order.append(key)
                convByKey[key] = (m.service, m.conversationId)
                nameByKey[key] = m.conversationName  // may be nil
            } else if nameByKey[key] == nil, let name = m.conversationName {
                nameByKey[key] = name  // upgrade nil → first real display name
            }
        }

        return order.compactMap { key in
            guard let conv = convByKey[key] else { return nil }
            let name = nameByKey[key] ?? conv.convId
            return (service: conv.service, convId: conv.convId, name: name)
        }
    }

    private func briefServices(for brief: Brief) -> [String] {
        guard let data = brief.services.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return arr
    }

    private func activePicker() -> (id: UUID, originalRequest: String, options: [ConversationOption])? {
        for item in threadItems.reversed() {
            if case .conversationPicker(let id, let req, let opts) = item {
                return (id, req, opts)
            }
        }
        return nil
    }

    private func removePicker(id: UUID) {
        threadItems.removeAll {
            if case .conversationPicker(let i, _, _) = $0 { return i == id }
            return false
        }
    }

    private func singleDigit(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count == 1, let n = Int(t) else { return nil }
        return n
    }

    /// Resolves a free-text input against an active picker's options. Priority:
    /// 1. A single digit equal to the option number.
    /// 2. Case-insensitive substring match against the option's displayName.
    /// 3. Case-insensitive match against the service's display name when the input
    ///    is the bare service word ("iMessage" / "signal" / "telegram" / "slack").
    /// Returns the unique winner only — ambiguous inputs return nil so the user
    /// can disambiguate further.
    private func resolvePickerChoice(_ rawInput: String,
                                     options: [ConversationOption]) -> ConversationOption? {
        let query = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }

        if let n = singleDigit(query), n >= 1 && n <= options.count {
            return options[n - 1]
        }

        let lower = query.lowercased()
        let nameMatches = options.filter { opt in
            opt.displayName.lowercased().contains(lower)
        }
        if nameMatches.count == 1 { return nameMatches[0] }

        let serviceMatches = options.filter {
            Theme.serviceName($0.service).lowercased() == lower
                || $0.service.lowercased() == lower
        }
        if serviceMatches.count == 1 { return serviceMatches[0] }

        return nil
    }

    /// Parses "write/send/reply/message (to) <name>: <text>" into (name, text).
    /// Returns nil if the input doesn't match the pattern.
    private func extractNamedSend(from text: String) -> (name: String, message: String)? {
        let pattern = #"(?i)(?:write|send|reply|replay|respond|message)\s+(?:to\s+)?(.+?):\s*(.+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text,
                                           range: NSRange(text.startIndex..., in: text)),
              let nameRange = Range(match.range(at: 1), in: text),
              let msgRange  = Range(match.range(at: 2), in: text)
        else { return nil }
        let name = String(text[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let msg  = String(text[msgRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !msg.isEmpty else { return nil }
        return (name, msg)
    }

    private func extractNaturalReplyRequest(from text: String) -> NaturalReplyRequest? {
        if let request = extractQuotedReplyRequest(from: text) {
            return request
        }
        return extractColonReplyRequest(from: text)
    }

    private func extractQuotedReplyRequest(from text: String) -> NaturalReplyRequest? {
        let pattern = #"(?i)^\s*(?:write|send|reply|replay|respond|message)\s+(?:to\s+)?(.+?)\s+(?:"([^"]+)"|'([^']+)'|“([^”]+)”|‘([^’]+)’)(?:\s+(?:and|then|also)\s+(.+))?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nameRange = Range(match.range(at: 1), in: text)
        else { return nil }

        let quote = (2...5).compactMap { index -> String? in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
            return String(text[swiftRange])
        }.first

        guard let messageText = quote?.trimmingCharacters(in: .whitespacesAndNewlines),
              !messageText.isEmpty else { return nil }

        let followUp = optionalCapture(match: match, index: 6, in: text)
        let targetName = String(text[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetName.isEmpty else { return nil }
        return NaturalReplyRequest(targetName: targetName, messageText: messageText, followUpText: followUp)
    }

    private func extractColonReplyRequest(from text: String) -> NaturalReplyRequest? {
        let pattern = #"(?i)^\s*(?:write|send|reply|replay|respond|message)\s+(?:to\s+)?(.+?):\s*(.+?)(?:\s+(?:and|then|also)\s+(.+))?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nameRange = Range(match.range(at: 1), in: text),
              let messageRange = Range(match.range(at: 2), in: text)
        else { return nil }

        let targetName = String(text[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let messageText = String(text[messageRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetName.isEmpty, !messageText.isEmpty else { return nil }
        return NaturalReplyRequest(
            targetName: targetName,
            messageText: messageText,
            followUpText: optionalCapture(match: match, index: 3, in: text)
        )
    }

    private func optionalCapture(match: NSTextCheckingResult, index: Int, in text: String) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        let value = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func conversations(matching targetName: String) -> [(service: String, convId: String, name: String)] {
        let needle = targetName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return briefConvs.filter { conv in
            conv.name.lowercased().contains(needle)
                || conv.convId.lowercased().contains(needle)
                || Theme.serviceName(conv.service).lowercased().contains(needle)
        }
    }

    private func conversationOptions(
        from conversations: [(service: String, convId: String, name: String)]
    ) -> [ConversationOption] {
        conversations.enumerated().map { i, conv in
            ConversationOption(number: i + 1,
                               service: conv.service,
                               convId: conv.convId,
                               displayName: conv.name)
        }
    }

    private func conversationOptions(from conversations: [ChatConversationRef]) -> [ConversationOption] {
        conversations.enumerated().map { i, conv in
            ConversationOption(number: i + 1,
                               service: conv.service,
                               convId: conv.convId,
                               displayName: conv.name)
        }
    }

    private func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
