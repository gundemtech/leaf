import Foundation

/// Runtime-injected конфиг для Database. Точные значения — moat (`LeafControlCorePrivate`).
/// weakDefaults — слабые значения для CI и тестов (работают, но не production-ready).
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

/// Каноничный путь sqlite-файла.
public enum DatabasePath {
    public static let filename = "events.sqlite"
    public static let applicationSupportSubdir = "LeafControl"

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
