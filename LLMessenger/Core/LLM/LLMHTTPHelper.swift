// LLMessenger/Core/LLM/LLMHTTPHelper.swift
import Foundation

/// Executes a prepared URLRequest: timing, audit log, 429/4xx handling.
/// Returns the response body on success. Caller owns request construction and JSON parsing.
///
/// - Parameter mapNetworkError: Optional transform on the URLSession error message.
///   Use for provider-specific messages (e.g. Ollama "server not reachable").
func executeLLMRequest(
    _ request: URLRequest,
    session: URLSession,
    provider: String,
    mapNetworkError: ((Error) -> String)? = nil
) async throws -> Data {
    let start = Date()
    let data: Data
    let response: URLResponse
    do {
        (data, response) = try await session.data(for: request)
    } catch {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        NetworkAuditLog.shared.record(provider: provider, request: request,
                                      status: nil, durationMs: ms, error: error)
        throw LLMError.networkFailed(mapNetworkError?(error) ?? error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
    let durationMs = Int(Date().timeIntervalSince(start) * 1000)
    NetworkAuditLog.shared.record(provider: provider, request: request,
                                  status: http.statusCode, durationMs: durationMs, error: nil)
    if http.statusCode == 429 {
        let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap { Int($0) }
        throw LLMError.rateLimited(retryAfter: retryAfter)
    }
    if http.statusCode >= 400 {
        throw LLMError.providerError("HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
    }
    return data
}
