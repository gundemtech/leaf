import Foundation

public enum ZoomMeetingState: String, Sendable, Codable, Hashable {
    case notInMeeting = "not_in_meeting"
    case inMeeting = "in_meeting"
    case waitingRoom = "waiting_room"
    case screenSharing = "screen_sharing"
}

/// Phase Track-4 S2 — Zoom boundary value type. Meeting state always
/// crosses; the optional `ownMeetingTopic` only crosses if the user opts in
/// to the Mail/Zoom-style sub-field toggle. Participants / attendees /
/// password / chat / waiting-room participants never cross.
public struct ZoomObservation: AdapterObservation, Hashable {
    public let meetingState: ZoomMeetingState
    public let ownMeetingTopic: String?

    public init(meetingState: ZoomMeetingState, ownMeetingTopic: String?) {
        self.meetingState = meetingState
        self.ownMeetingTopic = ownMeetingTopic
    }
}
