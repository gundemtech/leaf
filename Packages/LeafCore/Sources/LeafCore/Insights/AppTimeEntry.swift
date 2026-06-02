import Foundation

public struct AppTimeEntry: Codable, Sendable, Hashable {
    public let bundleID: String
    public let duration: TimeInterval
    public let firstSeen: Date
    public let lastSeen: Date

    public init(bundleID: String, duration: TimeInterval, firstSeen: Date, lastSeen: Date) {
        self.bundleID = bundleID
        self.duration = duration
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

public struct FocusSession: Codable, Sendable, Hashable {
    /// Dominant app within the session (longest cumulative duration).
    public let bundleID: String
    public let start: Date
    public let end: Date
    /// Number of distinct bundle IDs touched within the session.
    /// `appCount == 1` — single-app focus; `> 1` — multi-app session, `bundleID`
    /// shows the dominant one.
    public let appCount: Int
    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public init(bundleID: String, start: Date, end: Date, appCount: Int = 1) {
        self.bundleID = bundleID
        self.start = start
        self.end = end
        self.appCount = appCount
    }
}
