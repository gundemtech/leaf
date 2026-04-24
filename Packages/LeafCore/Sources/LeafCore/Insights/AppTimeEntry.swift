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
    public let bundleID: String
    public let start: Date
    public let end: Date
    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public init(bundleID: String, start: Date, end: Date) {
        self.bundleID = bundleID
        self.start = start
        self.end = end
    }
}
