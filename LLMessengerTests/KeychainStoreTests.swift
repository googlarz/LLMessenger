// LLMessengerTests/KeychainStoreTests.swift
import XCTest
@testable import LLMessenger

final class KeychainStoreTests: XCTestCase {

    let testService = "com.llmessenger.test"

    override func tearDown() {
        try? KeychainStore(service: testService).delete(account: "anthropic")
        try? KeychainStore(service: testService).delete(account: "openai")
    }

    func testWriteAndReadKey() throws {
        let store = KeychainStore(service: testService)
        try store.set(account: "anthropic", value: "sk-ant-test-123")
        let read = try store.get(account: "anthropic")
        XCTAssertEqual(read, "sk-ant-test-123")
    }

    func testOverwriteExistingKey() throws {
        let store = KeychainStore(service: testService)
        try store.set(account: "openai", value: "sk-old")
        try store.set(account: "openai", value: "sk-new")
        XCTAssertEqual(try store.get(account: "openai"), "sk-new")
    }

    func testDeleteKey() throws {
        let store = KeychainStore(service: testService)
        try store.set(account: "anthropic", value: "sk-ant-test")
        try store.delete(account: "anthropic")
        XCTAssertThrowsError(try store.get(account: "anthropic"))
    }

    func testGetMissingKeyThrows() {
        let store = KeychainStore(service: testService)
        XCTAssertThrowsError(try store.get(account: "nonexistent"))
    }
}
