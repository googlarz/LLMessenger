// LLMessengerTests/KeychainStoreTests.swift
import XCTest
@testable import LLMessenger

final class KeychainStoreTests: XCTestCase {

    let store = KeychainStore()
    // Keys used by tests — cleaned up in tearDown.
    let testKeys = ["_test_anthropic", "_test_openai", "_test_nonexistent"]

    override func tearDown() {
        for key in testKeys {
            try? store.delete(account: key)
        }
    }

    func testWriteAndReadKey() throws {
        try store.set(account: "_test_anthropic", value: "sk-ant-test-123")
        let read = try store.get(account: "_test_anthropic")
        XCTAssertEqual(read, "sk-ant-test-123")
    }

    func testOverwriteExistingKey() throws {
        try store.set(account: "_test_openai", value: "sk-old")
        try store.set(account: "_test_openai", value: "sk-new")
        XCTAssertEqual(try store.get(account: "_test_openai"), "sk-new")
    }

    func testDeleteKey() throws {
        try store.set(account: "_test_anthropic", value: "sk-ant-test")
        try store.delete(account: "_test_anthropic")
        XCTAssertThrowsError(try store.get(account: "_test_anthropic"))
    }

    func testGetMissingKeyThrows() {
        XCTAssertThrowsError(try store.get(account: "_test_nonexistent"))
    }
}
