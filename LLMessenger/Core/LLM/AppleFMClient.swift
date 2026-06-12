// LLMessenger/Core/LLM/AppleFMClient.swift
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device LLM via Apple's Foundation Models framework (macOS 26+).
/// Zero setup, zero cost, nothing leaves the Mac.
enum AppleFM {
    /// True when the OS has the framework AND the device model is ready to use.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return false }
        return SystemLanguageModel.default.availability == .available
        #else
        return false
        #endif
    }

    /// Human-readable reason when unavailable (Apple Intelligence off, model downloading, old OS).
    static var unavailabilityReason: String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return "Requires macOS 26 or later" }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Enable Apple Intelligence in System Settings"
        case .unavailable(.modelNotReady):
            return "Model is downloading — try again shortly"
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence"
        case .unavailable:
            return "Apple Intelligence is unavailable"
        }
        #else
        return "Requires macOS 26 or later"
        #endif
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
struct AppleFMClient: LLMClient {
    func complete(model: String, messages: [LLMMessage], maxTokens: Int) async throws -> LLMResponse {
        guard SystemLanguageModel.default.availability == .available else {
            throw LLMError.providerError(AppleFM.unavailabilityReason ?? "Apple Intelligence is unavailable")
        }

        let instructions = messages.filter { $0.role == .system }
            .map(\.content).joined(separator: "\n\n")
        let prompt = messages.filter { $0.role != .system }
            .map { $0.role == .assistant ? "Assistant: \($0.content)" : $0.content }
            .joined(separator: "\n\n")

        let session = instructions.isEmpty
            ? LanguageModelSession()
            : LanguageModelSession(instructions: instructions)

        do {
            let response = try await session.respond(to: prompt)
            // Token counts aren't exposed by the framework; report 0 (on-device is free).
            return LLMResponse(text: response.content, inputTokens: 0, outputTokens: 0)
        } catch {
            // The 4k on-device context window is the most common failure for large briefs.
            let msg = String(describing: error)
            if msg.localizedCaseInsensitiveContains("context") {
                throw LLMError.providerError(
                    "Brief too large for the on-device model. Reduce the polling window or switch to Ollama/cloud in Settings."
                )
            }
            throw LLMError.providerError("On-device model failed: \(error.localizedDescription)")
        }
    }
}
#endif
