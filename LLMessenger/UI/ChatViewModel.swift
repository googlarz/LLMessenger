// LLMessenger/UI/ChatViewModel.swift
import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var threadItems: [ThreadItem] = []
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false

    private let appState: AppState
    private var currentBrief: Brief?
    // Ordered distinct conversations in the loaded brief; built once per loadBrief().
    private(set) var briefConvs: [(service: String, convId: String, name: String)] = []

    init(appState: AppState) {
        self.appState = appState
    }

    func loadBrief(_ brief: Brief) async throws {
        currentBrief = brief
        let messages = try appState.repository.fetchMessages(forBriefID: brief.id!)
        threadItems = messages.map { .message($0) }
        briefConvs = buildConvList(from: messages, brief: brief)
    }

    // MARK: - Send

    func send() async {
        let rawInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawInput.isEmpty, let brief = currentBrief else { return }
        inputText = ""

        // Case 1 — Picker resolution: user typed a number to answer an active picker.
        if let picker = activePicker(),
           let n = singleDigit(rawInput),
           n >= 1 && n <= picker.options.count {
            let chosen = picker.options[n - 1]
            threadItems.append(.userMessage(id: UUID(), text: rawInput))
            removePicker(id: picker.id)
            await draftReply(brief: brief,
                             originalRequest: picker.originalRequest,
                             service: chosen.service,
                             convId: chosen.convId,
                             convName: chosen.displayName)
            return
        }

        // Case 2 — Named-send shortcut: "write/send/reply/message to X: text".
        // Resolve the target client-side — no LLM needed when the match is unambiguous.
        if let (targetName, messageText) = extractNamedSend(from: rawInput) {
            let matches = briefConvs.filter {
                $0.name.lowercased().contains(targetName.lowercased())
            }
            if matches.count == 1 {
                let conv = matches[0]
                threadItems.append(.userMessage(id: UUID(), text: rawInput))
                await draftReply(brief: brief,
                                 originalRequest: messageText,
                                 service: conv.service,
                                 convId: conv.convId,
                                 convName: conv.name)
                return
            } else if matches.count > 1 {
                let options = matches.enumerated().map { i, conv in
                    ConversationOption(number: i + 1,
                                       service: conv.service,
                                       convId: conv.convId,
                                       displayName: conv.name)
                }
                threadItems.append(.userMessage(id: UUID(), text: rawInput))
                threadItems.append(.conversationPicker(id: UUID(),
                                                       originalRequest: rawInput,
                                                       options: options))
                return
            }
            // Zero matches → fall through to LLM for a helpful reply.
        }

        // Case 3 — Normal: let the LLM understand intent and decide what to do.
        let userMsgID = UUID()
        threadItems.append(.userMessage(id: userMsgID, text: rawInput))
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

            if responseText.uppercased().hasPrefix("CHOOSE") {
                // LLM decided it needs the user to pick a conversation.
                let options = briefConvs.enumerated().map { i, conv in
                    ConversationOption(number: i + 1,
                                       service: conv.service,
                                       convId: conv.convId,
                                       displayName: conv.name)
                }
                threadItems.append(.conversationPicker(id: UUID(),
                                                       originalRequest: rawInput,
                                                       options: options))
            } else if let draftRange = responseText.range(of: "DRAFT:", options: .caseInsensitive),
                      draftRange.lowerBound == responseText.startIndex {
                // LLM drafted a reply. Format: DRAFT:<n>: <text> or DRAFT: <text> (single conv).
                let rest = String(responseText[draftRange.upperBound...])
                var target = briefConvs.first
                var draftText = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                // Parse optional "n: " prefix to identify which conversation.
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
        } catch {
            threadItems.append(.assistantResponse(id: UUID(),
                                                   text: "Error: \(error.localizedDescription)"))
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

    func sendDraft(_ draft: ReplyDraft) async throws {
        guard let adapter = appState.adapters[draft.serviceID] else {
            throw AdapterError.notRunning
        }
        try await adapter.send(conversationID: draft.conversationID, text: draft.text)
        try? appState.repository.storeSentMessage(
            service: draft.serviceID,
            conversationID: draft.conversationID,
            text: draft.text
        )
        discardDraft(id: draft.id)
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
        // Filter to the selected conversation so the LLM sees only relevant messages.
        let convMessages = briefMessages.filter { $0.service == service && $0.conversationId == convId }
        let contextMessages = (convMessages.isEmpty ? Array(briefMessages.suffix(30)) : Array(convMessages.suffix(30)))
        let briefText = contextMessages
            .map { "[\($0.sender)]: \($0.text)" }
            .joined(separator: "\n")

        let systemPrompt = PromptBuilder.build(
            mode: .chat(conversations: ["\(Theme.serviceName(service)) — \(convName)"]),
            basePrompt: appState.basePrompt,
            services: [service],
            episodicSummaries: [],
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
            let draftText: String
            if let range = responseText.range(of: "DRAFT:", options: .caseInsensitive) {
                draftText = String(responseText[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                draftText = responseText
            }
            let draft = ReplyDraft(id: UUID(), text: draftText,
                                   serviceID: service, conversationID: convId, senderName: "")
            threadItems.append(.replyDraft(id: draft.id, draft: draft))
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
            case .replyDraft(_, let draft):
                msgs.append(LLMMessage(role: .assistant, content: "DRAFT: \(draft.text)"))
            default:
                break
            }
        }
        msgs.append(LLMMessage(role: .user, content: currentText))
        return msgs
    }

    private func buildConvList(from messages: [Message],
                               brief: Brief) -> [(service: String, convId: String, name: String)] {
        var seen = Set<String>()
        var result: [(service: String, convId: String, name: String)] = []
        for m in messages {
            let key = "\(m.service):\(m.conversationId)"
            if seen.insert(key).inserted {
                // Prefer the stored display name; fall back to the raw conversation ID.
                let name = m.conversationName ?? m.conversationId
                result.append((service: m.service, convId: m.conversationId, name: name))
            }
        }
        return result
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

    /// Parses "write/send/reply/message (to) <name>: <text>" into (name, text).
    /// Returns nil if the input doesn't match the pattern.
    private func extractNamedSend(from text: String) -> (name: String, message: String)? {
        let pattern = #"(?i)(?:write|send|reply|message)\s+(?:to\s+)?(.+?):\s*(.+)"#
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
}
