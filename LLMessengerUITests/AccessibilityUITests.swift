import XCTest

@MainActor
final class AccessibilityUITests: XCTestCase {
    func testMainWindowPassesAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LLMESSENGER_UI_TEST_MODE"] = "1"
        app.launch()

        XCTAssertTrue(app.windows["LLMessenger"].waitForExistence(timeout: 10))
        // Contrast is gated deterministically in ThemeContrastTests. XCTest's screenshot
        // audit misclassifies virtual accessibility representations and clipped ScrollView
        // descendants because they do not have sampleable on-screen pixels.
        try app.performAccessibilityAudit(for: [
            .action,
            .elementDetection,
            .hitRegion,
            .parentChild,
            .sufficientElementDescription
        ]) { issue in
            print("AXAUDIT [\(issue.auditType.rawValue)] \(issue.compactDescription): \(issue.detailedDescription) element=\(String(describing: issue.element))")
            if let element = issue.element {
                if element.elementType == .touchBar {
                    return true
                }
                let frame = element.frame
                if issue.auditType == .parentChild, frame.width <= 16, frame.height <= 16 {
                    return true
                }
                if frame.width <= 1, frame.height <= 1 {
                    return true
                }
            }
            return false
        }
    }
}
