import Foundation

/// Single point-in-time snapshot of activity — the most recent attention event,
/// optionally filtered by bundle ID. Used by the `lastActivity` query
/// and the MCP `find_last_activity` tool.
public struct ActivitySnapshot: Codable, Sendable, Hashable {
    public let bundleID: String
    public let timestamp: Date

    public init(bundleID: String, timestamp: Date) {
        self.bundleID = bundleID
        self.timestamp = timestamp
    }
}
