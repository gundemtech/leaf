import Foundation

/// Runtime-injected config for Database. Exact values are moat (`LeafCorePrivate`).
/// weakDefaults are weak values for CI and tests (they work, but are not production-ready).
public struct DatabaseConfig: Sendable, Hashable {
    public let busyTimeoutMs: Int
    public let walCheckpointIntervalSec: TimeInterval
    public let walCheckpointMaxBytes: Int

    public init(busyTimeoutMs: Int, walCheckpointIntervalSec: TimeInterval, walCheckpointMaxBytes: Int) {
        self.busyTimeoutMs = busyTimeoutMs
        self.walCheckpointIntervalSec = walCheckpointIntervalSec
        self.walCheckpointMaxBytes = walCheckpointMaxBytes
    }

    public static let weakDefaults = DatabaseConfig(
        busyTimeoutMs: 1000,
        walCheckpointIntervalSec: 60,
        walCheckpointMaxBytes: 1_048_576
    )
}

/// Canonical path of the sqlite file.
public enum DatabasePath {
    public static let filename = "events.sqlite"

    /// Application Support subdir, isolated per build flavour. A Debug build
    /// (bundle id contains ".debug") resolves to "Leaf-Debug" so it can never
    /// open/clobber the prod "Leaf/events.sqlite" — prod is SQLCipher-encrypted,
    /// Debug is plaintext, and sharing one file produced the 4KB-stub corruption.
    /// All three prod processes (app/agent/mcp) share "Leaf"; all three debug
    /// processes share "Leaf-Debug".
    public static var applicationSupportSubdir: String {
        subdir(forBundleID: Bundle.main.bundleIdentifier)
    }

    /// Pure, testable resolver: "Leaf-Debug" for any *.debug* bundle id, else "Leaf".
    public static func subdir(forBundleID bundleID: String?) -> String {
        if let bundleID, bundleID.contains(".debug") { return "Leaf-Debug" }
        return "Leaf"
    }

    public static func defaultURL() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent(applicationSupportSubdir, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }
}
