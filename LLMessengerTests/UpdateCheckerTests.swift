// LLMessengerTests/UpdateCheckerTests.swift
import XCTest
@testable import LLMessenger

final class UpdateCheckerTests: XCTestCase {

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isVersion("1.5.0", newerThan: "1.4.3"))
        XCTAssertTrue(UpdateChecker.isVersion("2.0", newerThan: "1.9.9"))
        XCTAssertTrue(UpdateChecker.isVersion("1.10.0", newerThan: "1.9.3"),
                      "Numeric comparison, not lexicographic")
        XCTAssertTrue(UpdateChecker.isVersion("1.4.3.1", newerThan: "1.4.3"))

        XCTAssertFalse(UpdateChecker.isVersion("1.4.3", newerThan: "1.4.3"))
        XCTAssertFalse(UpdateChecker.isVersion("1.4.2", newerThan: "1.4.3"))
        XCTAssertFalse(UpdateChecker.isVersion("1.4", newerThan: "1.4.0"),
                       "Missing components count as zero")
        XCTAssertFalse(UpdateChecker.isVersion("0.9", newerThan: "1.0"))
    }
}
