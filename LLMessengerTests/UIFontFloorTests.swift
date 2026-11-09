import XCTest
@testable import LLMessenger

/// README and DESIGN.md promise no text below 10pt. `Theme.sans/mono/display`
/// clamp to `Theme.minimumFontSize`; this scan catches the other way in — a
/// literal `.system(size: 9)` or `Theme.mono(8)` typed straight into a view.
final class UIFontFloorTests: XCTestCase {
    func testNoFontBelowTenPointsInUISources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let uiDir = root.appendingPathComponent("LLMessenger/UI")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: uiDir, includingPropertiesForKeys: nil))

        // .system(size: 9)  /  Theme.mono(9.5)  /  .sans(8, weight: …)
        let pattern = try NSRegularExpression(
            pattern: #"(?:\.system\(\s*size:|\b(?:mono|sans|display)\()\s*([0-9]+(?:\.[0-9]+)?)\b"#)

        var failures: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
            let source = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let range = NSRange(line.startIndex..., in: line)
                for match in pattern.matches(in: line, range: range) {
                    guard let r = Range(match.range(at: 1), in: line),
                          let size = Double(line[r]), size < Theme.minimumFontSize else { continue }
                    failures.append("\(relative):\(index + 1): size \(size)")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "Font below \(Theme.minimumFontSize)pt:\n" + failures.joined(separator: "\n"))
    }

    func testAnnouncementTextNamesTheAvailableAction() {
        XCTAssertEqual(A11y.spoken("Skipped", actionTitle: "Undo"), "Skipped. Undo available.")
        XCTAssertEqual(A11y.spoken("Dismissed owed reply.", actionTitle: "Undo"), "Dismissed owed reply. Undo available.")
        XCTAssertEqual(A11y.spoken("First digest ready.", actionTitle: nil), "First digest ready.")
        let problem = UserReceipt(text: "Couldn't send to Anna", actionTitle: "Show", tone: .problem, action: {})
        XCTAssertEqual(problem.spokenText, "Problem. Couldn't send to Anna. Show available.")
    }

    func testToastsStayLongerForVoiceOver() {
        XCTAssertEqual(A11y.toastDuration(hasAction: true, voiceOver: false), 6)
        XCTAssertGreaterThanOrEqual(A11y.toastDuration(hasAction: true, voiceOver: true), 20)
        XCTAssertGreaterThan(A11y.toastDuration(hasAction: false, voiceOver: true),
                             A11y.toastDuration(hasAction: false, voiceOver: false))
    }
}
