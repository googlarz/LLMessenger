import CryptoKit
import Foundation
import GRDB

/// Shared dispatch point for every production LLM call. Provider credentials and
/// prompt/response text stay in memory; the database receives metadata and hashes only.
final class LLMGateway: LLMClient, @unchecked Sendable {
    private static let hashKey = SymmetricKey(size: .bits256)

    private struct Configuration {
        let client: any LLMClient
        let provider: LLMProvider?
        let model: String
    }

    private struct FittedPrompt {
        let messages: [LLMMessage]
        let tokenEstimate: Int
        let wasTruncated: Bool
    }

    private let database: AppDatabase
    private let lock = NSLock()
    private let contextTokenLimitOverride: Int?
    private let localOnlyMode: @Sendable () -> Bool
    private var configuration: Configuration

    init(
        database: AppDatabase,
        client: any LLMClient,
        provider: LLMProvider?,
        model: String,
        contextTokenLimitOverride: Int? = nil,
        localOnlyMode: @escaping @Sendable () -> Bool = {
            SettingsRepository().loadLocalOnlyMode()
        }
    ) {
        self.database = database
        self.configuration = Configuration(client: client, provider: provider, model: model)
        self.contextTokenLimitOverride = contextTokenLimitOverride
        self.localOnlyMode = localOnlyMode
    }

    var isLocal: Bool { snapshot().client.isLocal }

    func update(client: any LLMClient, provider: LLMProvider?, model: String) {
        lock.lock()
        configuration = Configuration(client: client, provider: provider, model: model)
        lock.unlock()
    }

    func complete(
        model requestedModel: String,
        messages: [LLMMessage],
        maxTokens: Int
    ) async throws -> LLMResponse {
        let config = snapshot()
        guard !localOnlyMode() || config.client.isLocal else {
            throw LLMError.egressBlocked
        }
        let model = config.model.isEmpty ? requestedModel : config.model
        let contextLimit = contextTokenLimitOverride
            ?? Self.contextTokenLimit(provider: config.provider)
        let effectiveMaxTokens = min(max(1, maxTokens), max(256, contextLimit / 4))
        let inputBudget = max(256, contextLimit - effectiveMaxTokens - 256)
        let fitted = Self.fit(messages: messages, tokenBudget: inputBudget)
        let metadata = LLMInvocationContext.metadata
        let startedAt = Date()
        let backend = config.provider?.rawValue ?? "unconfigured"
        let promptHash = Self.hash(messages: fitted.messages)
        let runID = insertStartedRun(
            metadata: metadata,
            backend: backend,
            model: model,
            startedAt: startedAt,
            promptHash: promptHash,
            promptTokenEstimate: fitted.tokenEstimate,
            requestedMaxTokens: effectiveMaxTokens,
            wasTruncated: fitted.wasTruncated
        )

        do {
            let response = try await config.client.complete(
                model: model,
                messages: fitted.messages,
                maxTokens: effectiveMaxTokens
            )
            let inputTokens = response.inputTokens > 0
                ? response.inputTokens
                : fitted.tokenEstimate
            let outputTokens = response.outputTokens > 0
                ? response.outputTokens
                : TokenEstimator.estimate(response.text)
            finishRun(
                id: runID,
                startedAt: startedAt,
                status: "succeeded",
                errorCategory: nil,
                responseHash: Self.hash(response.text),
                inputTokens: inputTokens,
                outputTokens: outputTokens
            )
            return response
        } catch {
            finishRun(
                id: runID,
                startedAt: startedAt,
                status: "failed",
                errorCategory: Self.errorCategory(error),
                responseHash: nil,
                inputTokens: fitted.tokenEstimate,
                outputTokens: 0
            )
            throw error
        }
    }

    private func snapshot() -> Configuration {
        lock.lock()
        defer { lock.unlock() }
        return configuration
    }

    private func insertStartedRun(
        metadata: LLMInvocationMetadata,
        backend: String,
        model: String,
        startedAt: Date,
        promptHash: String,
        promptTokenEstimate: Int,
        requestedMaxTokens: Int,
        wasTruncated: Bool
    ) -> Int64? {
        try? database.dbQueue.write { db in
            var record = LLMRunRecord(
                briefId: metadata.briefId,
                service: metadata.service,
                conversationId: metadata.conversationId,
                backend: backend,
                model: model,
                startedAt: startedAt,
                completedAt: nil,
                status: "running",
                errorCategory: nil,
                promptHash: promptHash,
                responseHash: nil,
                inputTokenEstimate: promptTokenEstimate,
                outputTokenEstimate: nil,
                purpose: metadata.purpose.rawValue,
                durationMs: nil,
                requestedMaxTokens: requestedMaxTokens,
                wasTruncated: wasTruncated
            )
            try record.insert(db)
            return record.id
        }
    }

    private func finishRun(
        id: Int64?,
        startedAt: Date,
        status: String,
        errorCategory: String?,
        responseHash: String?,
        inputTokens: Int,
        outputTokens: Int
    ) {
        guard let id else { return }
        let completedAt = Date()
        let durationMs = max(0, Int(completedAt.timeIntervalSince(startedAt) * 1000))
        try? database.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE llmRuns
                    SET completedAt = ?, status = ?, errorCategory = ?, responseHash = ?,
                        inputTokenEstimate = ?, outputTokenEstimate = ?, durationMs = ?
                    WHERE id = ?
                    """,
                arguments: [
                    completedAt, status, errorCategory, responseHash,
                    inputTokens, outputTokens, durationMs, id
                ]
            )
        }
    }

    private static func contextTokenLimit(provider: LLMProvider?) -> Int {
        switch provider {
        case .anthropic: return 180_000
        case .openai: return 120_000
        case .ollama:
            let configured = UserDefaults.standard.integer(forKey: "ollama_context_tokens")
            return configured > 0 ? configured : 32_000
        case .appleIntelligence: return 8_000
        case nil: return 32_000
        }
    }

    private static func fit(messages: [LLMMessage], tokenBudget: Int) -> FittedPrompt {
        let total = TokenEstimator.estimate(messages.map(\.content))
        guard total > tokenBudget else {
            return FittedPrompt(messages: messages, tokenEstimate: total, wasTruncated: false)
        }

        let systemMessages = messages.filter { $0.role == .system }
        let conversationMessages = messages.filter { $0.role != .system }
        let systemBudget = conversationMessages.isEmpty ? tokenBudget : max(256, tokenBudget * 3 / 5)
        let fittedSystem = fitInOrder(systemMessages, tokenBudget: systemBudget)
        let systemTokens = TokenEstimator.estimate(fittedSystem.map(\.content))
        var remaining = max(0, tokenBudget - systemTokens)
        var recentReversed: [LLMMessage] = []

        for message in conversationMessages.reversed() where remaining > 0 {
            let cost = TokenEstimator.estimate(message.content)
            if cost <= remaining {
                recentReversed.append(message)
                remaining -= cost
            } else if recentReversed.isEmpty {
                recentReversed.append(LLMMessage(
                    role: message.role,
                    content: truncateMiddle(message.content, tokenBudget: remaining)
                ))
                remaining = 0
            }
        }

        let fitted = fittedSystem + recentReversed.reversed()
        return FittedPrompt(
            messages: fitted,
            tokenEstimate: TokenEstimator.estimate(fitted.map(\.content)),
            wasTruncated: fitted != messages
        )
    }

    private static func fitInOrder(_ messages: [LLMMessage], tokenBudget: Int) -> [LLMMessage] {
        var remaining = tokenBudget
        var result: [LLMMessage] = []
        for message in messages where remaining > 0 {
            let cost = TokenEstimator.estimate(message.content)
            if cost <= remaining {
                result.append(message)
                remaining -= cost
            } else {
                result.append(LLMMessage(
                    role: message.role,
                    content: truncateMiddle(message.content, tokenBudget: remaining)
                ))
                break
            }
        }
        return result
    }

    private static func truncateMiddle(_ text: String, tokenBudget: Int) -> String {
        guard tokenBudget > 0, TokenEstimator.estimate(text) > tokenBudget else { return text }
        let marker = "\n[...truncated to fit model context...]\n"
        let characterBudget = max(0, tokenBudget * 4 - marker.count)
        let prefixCount = characterBudget * 3 / 5
        let suffixCount = characterBudget - prefixCount
        return String(text.prefix(prefixCount)) + marker + String(text.suffix(suffixCount))
    }

    private static func hash(messages: [LLMMessage]) -> String {
        let value = messages
            .map { "\($0.role.rawValue)\u{1E}\($0.content)" }
            .joined(separator: "\u{1F}")
        return hash(value)
    }

    private static func hash(_ value: String) -> String {
        HMAC<SHA256>
            .authenticationCode(for: Data(value.utf8), using: hashKey)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func errorCategory(_ error: Error) -> String {
        switch error {
        case LLMError.networkFailed: return "network"
        case LLMError.invalidResponse: return "invalid_response"
        case LLMError.missingAPIKey: return "missing_api_key"
        case LLMError.providerError: return "provider"
        case LLMError.rateLimited: return "rate_limited"
        case LLMError.egressBlocked: return "egress_blocked"
        default: return String(describing: type(of: error))
        }
    }
}
