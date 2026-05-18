import Foundation

public enum YouNowState: Equatable, Hashable, Sendable {
    case active(YouNowActive)
    case inMeeting(YouNowMeeting)
    case deepWorkFocus(YouNowFocus)
    case away(YouNowAway)
}

public struct YouNowActive: Equatable, Hashable, Sendable {
    public let app: String
    public let contextLabel: String?
    public let branch: String?
    public let linearID: String?
    public let durationSec: Int
    public let intensityBars: Int

    public init(
        app: String, contextLabel: String?, branch: String?, linearID: String?,
        durationSec: Int, intensityBars: Int
    ) {
        self.app = app
        self.contextLabel = contextLabel
        self.branch = branch
        self.linearID = linearID
        self.durationSec = durationSec
        self.intensityBars = intensityBars
    }
}

public struct YouNowMeeting: Equatable, Hashable, Sendable {
    public let titleIfAvailable: String?
    public let startedAtMs: Int64
    public let endsAtMsIfAvailable: Int64?
    public let source: MeetingSource

    public init(
        titleIfAvailable: String?, startedAtMs: Int64,
        endsAtMsIfAvailable: Int64?, source: MeetingSource
    ) {
        self.titleIfAvailable = titleIfAvailable
        self.startedAtMs = startedAtMs
        self.endsAtMsIfAvailable = endsAtMsIfAvailable
        self.source = source
    }
}

public enum MeetingSource: String, Equatable, Hashable, Sendable {
    case eventKit
    case zoom
    case both
}

public struct YouNowFocus: Equatable, Hashable, Sendable {
    public let modeName: String?
    public let app: String?
    public let contextLabel: String?
    public let durationSec: Int

    public init(modeName: String?, app: String?, contextLabel: String?, durationSec: Int) {
        self.modeName = modeName
        self.app = app
        self.contextLabel = contextLabel
        self.durationSec = durationSec
    }
}

public struct YouNowAway: Equatable, Hashable, Sendable {
    public let reason: AwayReason
    public let lastApp: String?
    public let lastContextLabel: String?
    public let lastLinearID: String?
    public let idleSec: Int

    public init(
        reason: AwayReason, lastApp: String?, lastContextLabel: String?,
        lastLinearID: String?, idleSec: Int
    ) {
        self.reason = reason
        self.lastApp = lastApp
        self.lastContextLabel = lastContextLabel
        self.lastLinearID = lastLinearID
        self.idleSec = idleSec
    }
}

public enum AwayReason: String, Equatable, Hashable, Sendable {
    case screenLocked
    case idle
    case sleep
}
