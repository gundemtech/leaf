import Foundation

/// Derived view, композит из Attention + Context + Content@L≤team_ceiling.
/// Это то, что уходит в presence-relay после Share Controls filter + encryption.
public struct PresenceSnapshot: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case active
        case activeGeneric
        case inMeeting
        case focusMode
        case idle
        case away
        case invisible
    }

    public let userID: String
    public let timestamp: Date
    public let status: Status
    public let appBundleID: String?
    public let granularity: Granularity?

    public init(
        userID: String,
        timestamp: Date = Date(),
        status: Status,
        appBundleID: String? = nil,
        granularity: Granularity? = nil
    ) {
        self.userID = userID
        self.timestamp = timestamp
        self.status = status
        self.appBundleID = appBundleID
        self.granularity = granularity
    }
}
