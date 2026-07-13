import XCTest
@testable import LLMessenger

@MainActor
final class NetworkAuditLogTests: XCTestCase {
    func testAuditEntryDropsQueryHeadersBodiesAndErrorDetails() async throws {
        NetworkAuditLog.shared.clear()
        let secret = "top-secret-message"
        var request = URLRequest(url: try XCTUnwrap(URL(
            string: "https://api.example.com/v1/messages?user=alice&token=\(secret)"
        )))
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(secret.utf8)

        NetworkAuditLog.record(
            provider: "Test",
            request: request,
            status: nil,
            durationMs: 4,
            error: LLMError.providerError(secret)
        )
        await waitForEntry()

        let entry = try XCTUnwrap(NetworkAuditLog.shared.entries.first)
        XCTAssertEqual(entry.endpoint, "api.example.com/v1/messages")
        XCTAssertEqual(entry.requestBytes, secret.utf8.count)
        XCTAssertEqual(entry.error, "LLMError")
        XCTAssertFalse(String(describing: entry).contains(secret))
    }

    func testLocalhostClassificationIsMetadataOnly() async throws {
        NetworkAuditLog.shared.clear()
        let request = URLRequest(url: try XCTUnwrap(URL(
            string: "http://127.0.0.1:11434/api/chat?prompt=private"
        )))

        NetworkAuditLog.record(
            provider: "Ollama",
            request: request,
            status: 200,
            durationMs: 2,
            error: nil
        )
        await waitForEntry()

        let entry = try XCTUnwrap(NetworkAuditLog.shared.entries.first)
        XCTAssertTrue(entry.isLocal)
        XCTAssertEqual(entry.endpoint, "127.0.0.1/api/chat")
        XCTAssertFalse(entry.endpoint.contains("private"))
    }

    private func waitForEntry() async {
        for _ in 0..<20 where NetworkAuditLog.shared.entries.isEmpty {
            await Task.yield()
        }
    }
}
