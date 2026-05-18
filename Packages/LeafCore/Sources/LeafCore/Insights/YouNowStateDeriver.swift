import Foundation

public struct YouNowInputs: Equatable, Sendable {
    public let frontmostAppName: String?
    public let frontmostBundleID: String?
    public let contextLabel: String?
    public let branch: String?
    public let linearID: String?
    public let activeSessionStartedAtMs: Int64?
    public let intensityBars: Int
    public let idleSec: Int
    public let screenLocked: Bool
    public let meetingActive: Bool
    public let meetingTitle: String?
    public let meetingStartedAtMs: Int64?
    public let meetingEndsAtMs: Int64?
    public let meetingSource: MeetingSource?
    public let focusActive: Bool
    public let focusModeName: String?
    public let nowMs: Int64

    public init(frontmostAppName: String?, frontmostBundleID: String?,
                contextLabel: String?, branch: String?, linearID: String?,
                activeSessionStartedAtMs: Int64?, intensityBars: Int,
                idleSec: Int, screenLocked: Bool,
                meetingActive: Bool, meetingTitle: String?,
                meetingStartedAtMs: Int64?, meetingEndsAtMs: Int64?,
                meetingSource: MeetingSource?,
                focusActive: Bool, focusModeName: String?, nowMs: Int64) {
        self.frontmostAppName = frontmostAppName
        self.frontmostBundleID = frontmostBundleID
        self.contextLabel = contextLabel
        self.branch = branch
        self.linearID = linearID
        self.activeSessionStartedAtMs = activeSessionStartedAtMs
        self.intensityBars = intensityBars
        self.idleSec = idleSec
        self.screenLocked = screenLocked
        self.meetingActive = meetingActive
        self.meetingTitle = meetingTitle
        self.meetingStartedAtMs = meetingStartedAtMs
        self.meetingEndsAtMs = meetingEndsAtMs
        self.meetingSource = meetingSource
        self.focusActive = focusActive
        self.focusModeName = focusModeName
        self.nowMs = nowMs
    }
}

public enum YouNowStateDeriver {
    /// Priority: inMeeting > deepWorkFocus > away(screenLocked) > away(idle) > active > away(idle, degenerate).
    /// Default idle threshold: 300 seconds (5 min).
    public static func derive(_ inputs: YouNowInputs, idleThresholdSec: Int = 300) -> YouNowState {
        if inputs.meetingActive {
            return .inMeeting(YouNowMeeting(
                titleIfAvailable: inputs.meetingTitle,
                startedAtMs: inputs.meetingStartedAtMs ?? inputs.nowMs,
                endsAtMsIfAvailable: inputs.meetingEndsAtMs,
                source: inputs.meetingSource ?? .eventKit
            ))
        }

        if inputs.focusActive && inputs.idleSec < idleThresholdSec {
            return .deepWorkFocus(YouNowFocus(
                modeName: inputs.focusModeName,
                app: inputs.frontmostAppName,
                contextLabel: inputs.contextLabel,
                durationSec: durationSec(from: inputs.activeSessionStartedAtMs, now: inputs.nowMs)
            ))
        }

        if inputs.screenLocked {
            return .away(YouNowAway(
                reason: .screenLocked,
                lastApp: inputs.frontmostAppName,
                lastContextLabel: inputs.contextLabel,
                lastLinearID: inputs.linearID,
                idleSec: inputs.idleSec
            ))
        }

        if inputs.idleSec >= idleThresholdSec {
            return .away(YouNowAway(
                reason: .idle,
                lastApp: inputs.frontmostAppName,
                lastContextLabel: inputs.contextLabel,
                lastLinearID: inputs.linearID,
                idleSec: inputs.idleSec
            ))
        }

        if let app = inputs.frontmostAppName {
            return .active(YouNowActive(
                app: app,
                contextLabel: inputs.contextLabel,
                branch: inputs.branch,
                linearID: inputs.linearID,
                durationSec: durationSec(from: inputs.activeSessionStartedAtMs, now: inputs.nowMs),
                intensityBars: inputs.intensityBars
            ))
        }

        return .away(YouNowAway(
            reason: .idle,
            lastApp: nil,
            lastContextLabel: nil,
            lastLinearID: nil,
            idleSec: inputs.idleSec
        ))
    }

    private static func durationSec(from startMs: Int64?, now: Int64) -> Int {
        guard let s = startMs, now > s else { return 0 }
        return Int((now - s) / 1000)
    }
}
