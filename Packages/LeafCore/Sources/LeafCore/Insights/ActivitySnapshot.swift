import Foundation

/// Single point-in-time snapshot активности — последний attention event,
/// опционально отфильтрованный по bundle ID. Используется `lastActivity` query
/// и MCP `find_last_activity` tool.
public struct ActivitySnapshot: Codable, Sendable, Hashable {
    public let bundleID: String
    public let timestamp: Date

    public init(bundleID: String, timestamp: Date) {
        self.bundleID = bundleID
        self.timestamp = timestamp
    }
}
