// LLMessengerTests/AutoLaunchManagerTests.swift
import XCTest
import ServiceManagement
@testable import LLMessenger

final class AutoLaunchManagerTests: XCTestCase {

    func testIsEnabledReturnsBool() {
        // Verify the property is readable without crashing
        let _ = AutoLaunchManager.isEnabled
    }

    func testTypeExists() {
        XCTAssertNotNil(AutoLaunchManager.self)
    }
}
