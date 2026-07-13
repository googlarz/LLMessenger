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
                // Toolbar menu buttons (SwiftUI Menu bridged to NSMenuToolbarItem)
                // expose AXShowMenu, not AXPress; the audit only counts the latter
                // as a click action. VoiceOver operates them via Show Menu. Newer
                // XCTest builds map the same control to .popUpButton and also miss
                // its title-provided description.
                if element.elementType == .menuButton || element.elementType == .popUpButton,
                   issue.auditType == .action || issue.auditType == .sufficientElementDescription {
                    return true
                }
                // SwiftUI emits unlabeled AXGroup layout containers (ForEach/if
                // groupings inside LazyVStack); VoiceOver navigates through them
                // into their fully-labeled children. Content-bearing types
                // (buttons, statics, images) are still audited.
                if element.elementType == .other,
                   issue.auditType == .sufficientElementDescription {
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
