import Foundation

struct PluginDiscovery {
    /// Scans ~/.config/llmessenger/adapters/ for manifest.json files.
    /// Returns validated manifests only. Invalid manifests are logged and skipped.
    static func discover() throws -> [PluginManifest] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let adaptersDir = (home as NSString)
            .appendingPathComponent(".config/llmessenger/adapters")
        return try discoverIn(directory: adaptersDir, home: home)
    }

    /// Testable overload that scans an arbitrary directory with a given home root.
    static func discoverIn(directory adaptersDir: String, home: String) throws -> [PluginManifest] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: adaptersDir) else { return [] }

        let entries = try fm.contentsOfDirectory(atPath: adaptersDir)
        var results: [PluginManifest] = []

        for entry in entries {
            let manifestPath = (adaptersDir as NSString)
                .appendingPathComponent("\(entry)/manifest.json")
            guard fm.fileExists(atPath: manifestPath) else { continue }

            do {
                let manifest = try load(from: manifestPath, home: home)
                results.append(manifest)
            } catch {
                // Log and skip — one bad manifest must not block others.
                print("[PluginDiscovery] Skipping \(manifestPath): \(error)")
            }
        }

        return results
    }

    /// Validate a manifest against the given home root. Throws DiscoveryError on failure.
    /// Exposed for testing; production code uses discover() which calls load() internally.
    static func validate(manifest: PluginManifest, home: String) throws {
        guard manifest.protocolVersion == 1 else {
            throw DiscoveryError.unsupportedProtocolVersion(manifest.protocolVersion)
        }

        let resolvedBinary = (manifest.binary as NSString).standardizingPath
        let homeCanonical = (home as NSString).standardizingPath

        guard resolvedBinary.hasPrefix(homeCanonical + "/") ||
              resolvedBinary == homeCanonical else {
            throw DiscoveryError.pathOutsideHome(resolvedBinary)
        }

        guard FileManager.default.isExecutableFile(atPath: resolvedBinary) else {
            throw DiscoveryError.binaryNotExecutable(resolvedBinary)
        }
    }

    // MARK: - Private

    private static func load(from path: String, home: String) throws -> PluginManifest {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        guard manifest.protocolVersion == 1 else {
            throw DiscoveryError.unsupportedProtocolVersion(manifest.protocolVersion)
        }

        // Resolve the binary path so symlinks and relative components are
        // normalised before we check containment.
        let resolvedBinary = URL(fileURLWithPath: manifest.binary)
            .resolvingSymlinksInPath().path

        // Path traversal guard: binary must be inside the user's home directory.
        let homeCanonical = (home as NSString).standardizingPath
        guard resolvedBinary.hasPrefix(homeCanonical + "/") ||
              resolvedBinary == homeCanonical else {
            throw DiscoveryError.pathOutsideHome(resolvedBinary)
        }

        guard FileManager.default.isExecutableFile(atPath: resolvedBinary) else {
            throw DiscoveryError.binaryNotExecutable(resolvedBinary)
        }

        // Return a manifest whose binary is the resolved (canonical) path.
        return PluginManifest(
            name: manifest.name,
            binary: resolvedBinary,
            protocolVersion: manifest.protocolVersion,
            services: manifest.services
        )
    }
}

// MARK: - Errors

enum DiscoveryError: Error, LocalizedError {
    case unsupportedProtocolVersion(Int)
    case pathOutsideHome(String)
    case binaryNotExecutable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedProtocolVersion(let v):
            return "Unsupported protocolVersion \(v); only version 1 is supported"
        case .pathOutsideHome(let p):
            return "Binary path is outside the user home directory: \(p)"
        case .binaryNotExecutable(let p):
            return "Binary does not exist or is not executable: \(p)"
        }
    }
}
