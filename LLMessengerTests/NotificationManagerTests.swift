// LLMessengerTests/NotificationManagerTests.swift
import XCTest
@testable import LLMessenger

final class NotificationManagerTests: XCTestCase {

    func testBriefIDRoundTripsViaUserInfo() {
        let userInfo: [AnyHashable: Any] = ["briefID": Int64(42)]
        let extracted = NotificationManager.briefID(from: userInfo)
        XCTAssertEqual(extracted, 42)
    }

    func testBriefIDReturnsNilForMissingKey() {
        let extracted = NotificationManager.briefID(from: [:])
        XCTAssertNil(extracted)
    }

    func testBriefIDReturnsNilForWrongType() {
        let extracted = NotificationManager.briefID(from: ["briefID": "notAnInt"])
        XCTAssertNil(extracted)
    }

    func testNotificationCategoryIdentifier() {
        XCTAssertEqual(NotificationManager.categoryID, "LLMessenger.brief")
    }
}
