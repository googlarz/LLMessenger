// LLMessengerTests/UpdateCheckerTests.swift
import XCTest
@testable import LLMessenger

private final class UpdateCheckerURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (URLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let result = try XCTUnwrap(Self.handler)(request)
            client?.urlProtocol(self, didReceive: result.0, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
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

    func testUpdateCheckAppearsInMetadataOnlyNetworkAudit() async throws {
        NetworkAuditLog.shared.clear()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateCheckerURLProtocol.self]
        let session = URLSession(configuration: configuration)
        UpdateCheckerURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.github.com/repos/googlarz/LLMessenger/releases/latest"
            )
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            return (response, Data(#"{"tag_name":"v9.0.0","html_url":"https://github.com/googlarz/LLMessenger/releases/tag/v9.0.0"}"#.utf8))
        }

        let checker = UpdateChecker(session: session, currentVersion: "1.0.0")
        await checker.check()
        for _ in 0..<20 where NetworkAuditLog.shared.entries.isEmpty {
            await Task.yield()
        }

        let entry = try XCTUnwrap(NetworkAuditLog.shared.entries.first)
        XCTAssertEqual(entry.provider, "GitHub Updates")
        XCTAssertEqual(entry.endpoint, "api.github.com/repos/googlarz/LLMessenger/releases/latest")
        XCTAssertEqual(entry.requestBytes, 0)
        XCTAssertEqual(entry.status, 200)
    }
}
