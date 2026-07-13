import XCTest
import GRDB
@testable import LLMessenger

private final class GatewaySpyClient: LLMClient, @unchecked Sendable {
    var local = false
    var response = LLMResponse(text: "response text", inputTokens: 11, outputTokens: 7)
    var error: Error?
    var requestedModels: [String] = []
    var requestedMessages: [[LLMMessage]] = []
    var requestedMaxTokens: [Int] = []

    var isLocal: Bool { local }

    func complete(
        model: String,
        messages: [LLMMessage],
        maxTokens: Int
    ) async throws -> LLMResponse {
        requestedModels.append(model)
        requestedMessages.append(messages)
        requestedMaxTokens.append(maxTokens)
        if let error { throw error }
        return response
    }
}

final class LLMGatewayTests: XCTestCase {
    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    func testSuccessfulCallUsesCurrentModelAndStoresMetadataOnly() async throws {
        let db = try makeDB()
        let spy = GatewaySpyClient()
        let gateway = LLMGateway(
            database: db,
            client: spy,
            provider: .anthropic,
            model: "current-model",
            localOnlyMode: { false }
        )
        let messages = [LLMMessage(role: .user, content: "private prompt text")]

        _ = try await gateway.complete(
            model: "stale-model",
            messages: messages,
            maxTokens: 400,
            purpose: .realtimeTriage,
            service: "signal",
            conversationId: "c1"
        )

        XCTAssertEqual(spy.requestedModels, ["current-model"])
        XCTAssertEqual(spy.requestedMessages, [messages])
        let run = try await db.dbQueue.read { try LLMRunRecord.fetchOne($0) }
        XCTAssertEqual(run?.backend, "anthropic")
        XCTAssertEqual(run?.model, "current-model")
        XCTAssertEqual(run?.purpose, LLMRequestPurpose.realtimeTriage.rawValue)
        XCTAssertEqual(run?.service, "signal")
        XCTAssertEqual(run?.conversationId, "c1")
        XCTAssertEqual(run?.status, "succeeded")
        XCTAssertEqual(run?.inputTokenEstimate, 11)
        XCTAssertEqual(run?.outputTokenEstimate, 7)
        XCTAssertEqual(run?.requestedMaxTokens, 400)
        XCTAssertEqual(run?.wasTruncated, false)
        XCTAssertEqual(run?.promptHash?.count, 64)
        XCTAssertEqual(run?.responseHash?.count, 64)
        XCTAssertNotEqual(run?.promptHash, "private prompt text")
        XCTAssertNotEqual(run?.responseHash, "response text")
        XCTAssertNotNil(run?.completedAt)
        XCTAssertNotNil(run?.durationMs)
    }

    func testFailureIsRecordedAndRethrown() async throws {
        let db = try makeDB()
        let spy = GatewaySpyClient()
        spy.error = LLMError.rateLimited(retryAfter: 5)
        let gateway = LLMGateway(
            database: db,
            client: spy,
            provider: .openai,
            model: "gpt-test",
            localOnlyMode: { false }
        )

        do {
            _ = try await gateway.complete(
                model: "ignored",
                messages: [LLMMessage(role: .user, content: "hello")],
                maxTokens: 100,
                purpose: .chatAnswer
            )
            XCTFail("Expected the provider failure to be rethrown")
        } catch {
            XCTAssertTrue(error is LLMError)
        }

        let run = try await db.dbQueue.read { try LLMRunRecord.fetchOne($0) }
        XCTAssertEqual(run?.status, "failed")
        XCTAssertEqual(run?.errorCategory, "rate_limited")
        XCTAssertEqual(run?.outputTokenEstimate, 0)
        XCTAssertNil(run?.responseHash)
    }

    func testOversizedPromptIsFittedToContextBudgetAndKeepsBothEnds() async throws {
        let db = try makeDB()
        let spy = GatewaySpyClient()
        let gateway = LLMGateway(
            database: db,
            client: spy,
            provider: .ollama,
            model: "local-model",
            contextTokenLimitOverride: 1_000,
            localOnlyMode: { false }
        )
        let messages = [
            LLMMessage(
                role: .system,
                content: "SYSTEM-BEGIN" + String(repeating: "s", count: 4_000) + "SYSTEM-END"
            ),
            LLMMessage(
                role: .user,
                content: "USER-BEGIN" + String(repeating: "u", count: 6_000) + "USER-END"
            )
        ]

        _ = try await gateway.complete(
            model: "ignored",
            messages: messages,
            maxTokens: 200,
            purpose: .briefSummarization
        )

        let sent = try XCTUnwrap(spy.requestedMessages.first)
        XCTAssertLessThanOrEqual(TokenEstimator.estimate(sent.map(\.content)), 544)
        XCTAssertTrue(sent[0].content.hasPrefix("SYSTEM-BEGIN"))
        XCTAssertTrue(sent[0].content.hasSuffix("SYSTEM-END"))
        XCTAssertTrue(sent[1].content.hasPrefix("USER-BEGIN"))
        XCTAssertTrue(sent[1].content.hasSuffix("USER-END"))
        let run = try await db.dbQueue.read { try LLMRunRecord.fetchOne($0) }
        XCTAssertEqual(run?.wasTruncated, true)
    }

    func testProviderHotSwapUpdatesLocalityClientAndModel() async throws {
        let db = try makeDB()
        let local = GatewaySpyClient()
        local.local = true
        let cloud = GatewaySpyClient()
        let gateway = LLMGateway(
            database: db,
            client: local,
            provider: .ollama,
            model: "local-model",
            localOnlyMode: { false }
        )
        XCTAssertTrue(gateway.isLocal)

        gateway.update(client: cloud, provider: .openai, model: "cloud-model")
        XCTAssertFalse(gateway.isLocal)
        _ = try await gateway.complete(
            model: "stale-model",
            messages: [LLMMessage(role: .user, content: "hello")],
            maxTokens: 10,
            purpose: .settingsConnection
        )

        XCTAssertTrue(local.requestedModels.isEmpty)
        XCTAssertEqual(cloud.requestedModels, ["cloud-model"])
    }

    func testLocalOnlyModeBlocksStaleCloudConfigurationAtDispatchBoundary() async throws {
        let db = try makeDB()
        let cloud = GatewaySpyClient()
        let gateway = LLMGateway(
            database: db,
            client: cloud,
            provider: .openai,
            model: "cloud-model",
            localOnlyMode: { true }
        )

        do {
            _ = try await gateway.complete(
                model: "ignored",
                messages: [LLMMessage(role: .user, content: "private message")],
                maxTokens: 10,
                purpose: .chatAnswer
            )
            XCTFail("Expected local-only egress guard")
        } catch LLMError.egressBlocked {
            // Expected.
        }

        XCTAssertTrue(cloud.requestedMessages.isEmpty)
        let runCount = try await db.dbQueue.read { try LLMRunRecord.fetchCount($0) }
        XCTAssertEqual(runCount, 0, "Blocked prompts must not enter provider telemetry")
    }

    func testLocalOnlyModeStillAllowsOnDeviceClient() async throws {
        let db = try makeDB()
        let local = GatewaySpyClient()
        local.local = true
        let gateway = LLMGateway(
            database: db,
            client: local,
            provider: .ollama,
            model: "local-model",
            localOnlyMode: { true }
        )

        _ = try await gateway.complete(
            model: "ignored",
            messages: [LLMMessage(role: .user, content: "private message")],
            maxTokens: 10,
            purpose: .chatAnswer
        )

        XCTAssertEqual(local.requestedModels, ["local-model"])
    }
}
