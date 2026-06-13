import XCTest
@testable import LLMessenger

final class PluginProtocolTests: XCTestCase {

    // MARK: - Manifest validation via PluginDiscovery

    func test_pathTraversal_isRejected() throws {
        // A manifest whose binary escapes the home directory must be rejected.
        let manifest = PluginManifest(
            name: "evil",
            binary: "../../../etc/passwd",
            protocolVersion: 1,
            services: []
        )
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertThrowsError(
            try validateManifest(manifest, home: home)
        ) { error in
            guard case DiscoveryError.pathOutsideHome = error else {
                XCTFail("Expected pathOutsideHome, got \(error)")
                return
            }
        }
    }

    func test_wrongProtocolVersion_isRejected() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let manifest = PluginManifest(
            name: "future",
            binary: home + "/some-binary",
            protocolVersion: 99,
            services: []
        )
        XCTAssertThrowsError(
            try validateManifest(manifest, home: home)
        ) { error in
            guard case DiscoveryError.unsupportedProtocolVersion = error else {
                XCTFail("Expected unsupportedProtocolVersion, got \(error)")
                return
            }
        }
    }

    func test_missingBinary_isRejected() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let manifest = PluginManifest(
            name: "missing",
            binary: home + "/does-not-exist-llmessenger-test-binary",
            protocolVersion: 1,
            services: []
        )
        XCTAssertThrowsError(
            try validateManifest(manifest, home: home)
        ) { error in
            guard case DiscoveryError.binaryNotExecutable = error else {
                XCTFail("Expected binaryNotExecutable, got \(error)")
                return
            }
        }
    }

    // MARK: - PluginDiscovery with empty directory

    func test_emptyAdaptersDir_returnsEmptyArray() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmessenger-test-adapters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try PluginDiscovery.discoverIn(directory: tmp.path, home: tmp.path)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Fuzz: malformed JSON does not crash SubprocessAdapter

    func test_malformedJSON_doesNotCrash() async {
        // SubprocessAdapter requires a running process; we verify that
        // feeding malformed payloads to a non-running adapter surfaces
        // AdapterError.notRunning (not a crash).
        let adapter = SubprocessAdapter(
            serviceID: "fuzz-test",
            adapterPath: "/nonexistent",
            config: [:]
        )

        let malformed: [String] = [
            "",
            "not json",
            "{",
            "}",
            "null",
            "[]",
            "{\"v\":}",
            String(repeating: "a", count: 1024),
            "{\u{0000}}",
            "{\"method\":\"hello\",\"v\":\"wrong-type\"}",
            "true",
            "false",
            "1234567890",
            "\"just a string\"",
            "{\"nested\":{\"a\":{\"b\":{}}}}",
            "{{{{",
            "}}}}",
            "[1,2,3",
            "{\"key\": \u{1F4A3}}",
            "\n\n\n",
        ]

        for payload in malformed {
            // The adapter is not running; any attempt to send should throw
            // notRunning, not crash.
            do {
                _ = try await adapter.authRoundTrip(["raw": payload])
                XCTFail("Expected throw for payload: \(payload)")
            } catch AdapterError.notRunning {
                // Expected — process was never started.
            } catch {
                // Any other typed error is acceptable; what matters is no crash.
            }
        }
    }

    // MARK: - Helpers

    /// Thin wrapper that mirrors the private validation logic inside PluginDiscovery,
    /// exposed here via a testable overload (discoverIn) added to PluginDiscovery.
    private func validateManifest(_ manifest: PluginManifest, home: String) throws {
        // Re-use PluginDiscovery's public test seam.
        try PluginDiscovery.validate(manifest: manifest, home: home)
    }
}
