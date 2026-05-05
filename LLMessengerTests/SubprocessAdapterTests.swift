import XCTest
@testable import LLMessenger

final class SubprocessAdapterTests: XCTestCase {

    var scriptURL: URL!

    override func setUp() async throws {
        let script = """
        #!/usr/bin/env python3
        import sys, json

        for line in sys.stdin:
            req = json.loads(line.strip())
            action = req.get("action")
            if action == "init":
                print(json.dumps({"success": True}), flush=True)
            elif action == "fetch":
                print(json.dumps({"conversations": [
                    {"id": "c1", "name": "Test", "type": "dm", "messages": [
                        {"id": "m1", "sender": "Alice", "text": "hi",
                         "timestamp": "2026-05-05T20:00:00Z"}
                    ]}
                ]}), flush=True)
            elif action == "send":
                print(json.dumps({"success": True}), flush=True)
            elif action == "health":
                print(json.dumps({"status": "ok"}), flush=True)
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mock_adapter.py")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        scriptURL = url
    }

    func testStartAndFetch() async throws {
        let adapter = SubprocessAdapter(
            serviceID: "test",
            adapterPath: "/usr/bin/python3",
            adapterArgs: [scriptURL.path],
            config: [:]
        )
        try await adapter.start()

        let result = try await adapter.fetch(
            config: FetchConfig(mode: .byCount(last: 10))
        )
        XCTAssertEqual(result.conversations.count, 1)
        XCTAssertEqual(result.conversations[0].messages[0].text, "hi")
    }

    func testSend() async throws {
        let adapter = SubprocessAdapter(
            serviceID: "test",
            adapterPath: "/usr/bin/python3",
            adapterArgs: [scriptURL.path],
            config: [:]
        )
        try await adapter.start()
        try await adapter.send(conversationID: "c1", text: "hello back")
    }

    func testHealthCheck() async throws {
        let adapter = SubprocessAdapter(
            serviceID: "test",
            adapterPath: "/usr/bin/python3",
            adapterArgs: [scriptURL.path],
            config: [:]
        )
        try await adapter.start()
        let health = await adapter.healthCheck()
        XCTAssertEqual(health.status, .ok)
    }
}
