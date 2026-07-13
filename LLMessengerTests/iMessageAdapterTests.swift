import Foundation
import XCTest
@testable import LLMessenger

final class iMessageAdapterTests: XCTestCase {
    func testExtractTextFromLegacyAttributedBodyTypedstream() throws {
        let selector = NSSelectorFromString("archivedDataWithRootObject:")
        let archiver = try XCTUnwrap(NSClassFromString("NSArchiver") as? NSObject.Type)
        let attributedText = NSAttributedString(string: "  Legacy iMessage body  ")
        let data = try XCTUnwrap(
            archiver.perform(selector, with: attributedText)?.takeUnretainedValue() as? Data
        )

        XCTAssertEqual(
            iMessageAdapter.extractTextFromAttributedBody(data),
            "Legacy iMessage body"
        )
    }
}
