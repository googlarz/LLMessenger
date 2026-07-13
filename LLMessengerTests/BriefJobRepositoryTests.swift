import XCTest
import GRDB
@testable import LLMessenger

final class MutableTestClock: @unchecked Sendable {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

final class BriefJobRepositoryTests: XCTestCase {
    private func insertMessage(_ database: AppDatabase, id: String, at date: Date = Date()) throws -> Message {
        try database.dbQueue.write { db in
            var message = Message(
                briefId: nil,
                service: "signal",
                conversationId: "conversation",
                messageId: id,
                sender: "Alice",
                text: id,
                timestamp: date,
                isSent: false
            )
            try message.insert(db)
            return message
        }
    }

    func testClaimCreatesImmutableMessageSnapshot() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = BriefRepository(database: database)
        let start = Date(timeIntervalSince1970: 500)
        let first = try insertMessage(database, id: "first", at: start)

        let initial = try XCTUnwrap(repository.claimAutomaticBriefJob(messages: [first], now: start))
        try repository.markBriefJobFailed(jobID: try XCTUnwrap(initial.job.id), error: "offline", now: start)
        _ = try insertMessage(database, id: "later", at: start.addingTimeInterval(1))

        let replay = try XCTUnwrap(repository.claimAutomaticBriefJob(
            messages: try repository.fetchUnattachedMessages(),
            now: start.addingTimeInterval(61)
        ))

        XCTAssertEqual(replay.job.id, initial.job.id)
        XCTAssertEqual(replay.messages.map(\.messageId), ["first"])
        XCTAssertEqual(replay.job.attemptCount, 2)
    }

    func testPartialCompletionLeavesOnlyFailedInputsPending() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = BriefRepository(database: database)
        let start = Date(timeIntervalSince1970: 750)
        var signal = try insertMessage(database, id: "signal")
        var telegram = try insertMessage(database, id: "telegram")
        telegram.service = "telegram"
        try database.dbQueue.write { db in try telegram.update(db) }

        let snapshot = try XCTUnwrap(repository.claimAutomaticBriefJob(messages: [signal, telegram]))
        let jobID = try XCTUnwrap(snapshot.job.id)
        try database.dbQueue.write { db in
            var brief = Brief(createdAt: Date(), status: "ready", services: #"["signal"]"#,
                              openingSummary: nil, notificationText: "one", episodicSummary: nil)
            try brief.insert(db)
            let briefID = try XCTUnwrap(brief.id)
            try BriefRepository.attach(messages: [signal], toBriefID: briefID, db: db)
            try BriefRepository.completeBriefJob(
                jobID: jobID,
                messages: [signal],
                briefID: briefID,
                failedServices: ["telegram"],
                now: start,
                db: db
            )
            signal.briefId = briefID
        }

        let job = try XCTUnwrap(repository.fetchBriefJobs().first)
        XCTAssertEqual(job.jobStatus, .partial)
        let items = try repository.fetchBriefJobMessages(jobID: jobID)
        XCTAssertEqual(items.map(\.messageStatus), [.succeeded, .pending])

        let replay = try XCTUnwrap(repository.claimAutomaticBriefJob(
            messages: [],
            now: start.addingTimeInterval(61)
        ))
        XCTAssertEqual(replay.messages.map(\.messageId), ["telegram"])
    }

    func testReopeningDatabaseRequeuesInterruptedJob() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("brief-job-\(UUID().uuidString).db")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }

        var database: AppDatabase? = try AppDatabase(path: url.path)
        let message = try insertMessage(try XCTUnwrap(database), id: "interrupted")
        let first = try XCTUnwrap(
            BriefRepository(database: try XCTUnwrap(database)).claimAutomaticBriefJob(messages: [message])
        )
        XCTAssertEqual(first.job.jobStatus, .running)
        database = nil

        let reopened = try AppDatabase(path: url.path)
        let recovered = try XCTUnwrap(
            BriefRepository(database: reopened).claimAutomaticBriefJob(messages: [])
        )
        XCTAssertEqual(recovered.job.id, first.job.id)
        XCTAssertEqual(recovered.job.attemptCount, 2)
        XCTAssertEqual(recovered.messages.map(\.messageId), ["interrupted"])
    }

    func testFailedJobBackoffAllowsNewMessagesToCreateANewJob() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = BriefRepository(database: database)
        let start = Date(timeIntervalSince1970: 1_000)
        let failedMessage = try insertMessage(database, id: "failed", at: start)

        let first = try XCTUnwrap(repository.claimAutomaticBriefJob(messages: [failedMessage], now: start))
        let firstID = try XCTUnwrap(first.job.id)
        try repository.markBriefJobFailed(jobID: firstID, error: "offline", now: start)

        let laterMessage = try insertMessage(database, id: "later", at: start.addingTimeInterval(1))
        let next = try XCTUnwrap(repository.claimAutomaticBriefJob(
            messages: [failedMessage, laterMessage],
            now: start.addingTimeInterval(1)
        ))

        XCTAssertNotEqual(next.job.id, firstID)
        XCTAssertEqual(next.messages.map(\.messageId), ["later"])
        let failedJob = try XCTUnwrap(repository.fetchBriefJobs().first { $0.id == firstID })
        XCTAssertEqual(failedJob.jobStatus, .failed)
        XCTAssertEqual(failedJob.nextAttemptAt, start.addingTimeInterval(60))
    }

    func testRepeatedFailureMovesJobToDeadLetter() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = BriefRepository(database: database)
        let start = Date(timeIntervalSince1970: 2_000)
        let message = try insertMessage(database, id: "poison", at: start)
        var now = start

        for expectedAttempt in 1...BriefRepository.maximumBriefJobAttempts {
            let snapshot = try XCTUnwrap(repository.claimAutomaticBriefJob(messages: [message], now: now))
            XCTAssertEqual(snapshot.job.attemptCount, expectedAttempt)
            try repository.markBriefJobFailed(
                jobID: try XCTUnwrap(snapshot.job.id),
                error: "still offline",
                now: now
            )
            now = now.addingTimeInterval(BriefRepository.retryDelay(afterAttempt: expectedAttempt) + 1)
        }

        let job = try XCTUnwrap(repository.fetchBriefJobs().first)
        XCTAssertEqual(job.jobStatus, .deadLetter)
        XCTAssertNotNil(job.completedAt)
        XCTAssertNil(try repository.claimAutomaticBriefJob(messages: [message], now: now))
    }
}
