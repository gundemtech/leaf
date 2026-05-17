import Foundation

/// Phase Track-4 S2 — pure transition detector for Zoom. Emits up to two
/// events per tick:
///   - `zoom_meeting_state_changed` whenever `meetingState` flips
///     (always — meeting state has no third-party PII)
///   - `zoom_meeting_name_observed` whenever `ownMeetingTopic` actually
///     changes AND the caller passes `meetingTopicOptedIn: true`.
///
/// Either signal can fire independently in the same tick (or both, or none).
public struct ZoomStateMachine: Sendable, Hashable {
    private var prev: ZoomObservation?

    public init() {}

    public mutating func observe(
        _ obs: ZoomObservation,
        nowMs: Int64,
        meetingTopicOptedIn: Bool
    ) -> [RawEvent] {
        defer { prev = obs }
        var events: [RawEvent] = []
        let stateChanged: Bool = {
            guard let p = prev else { return true }
            return p.meetingState != obs.meetingState
        }()
        if stateChanged {
            let payload: [String: String] = [
                "event_kind": "zoom_meeting_state_changed",
                "meeting_state": obs.meetingState.rawValue,
            ]
            events.append(
                RawEvent(
                    timestamp: Date(timeIntervalSince1970: Double(nowMs) / 1000.0),
                    signalType: .context,
                    bundleID: "us.zoom.xos",
                    payload: payload
                ))
        }
        let topicChanged: Bool = {
            guard let p = prev else { return obs.ownMeetingTopic != nil }
            return p.ownMeetingTopic != obs.ownMeetingTopic
        }()
        if topicChanged, meetingTopicOptedIn, let topic = obs.ownMeetingTopic {
            let payload: [String: String] = [
                "event_kind": "zoom_meeting_name_observed",
                "meeting_topic": topic,
            ]
            events.append(
                RawEvent(
                    timestamp: Date(timeIntervalSince1970: Double(nowMs) / 1000.0),
                    signalType: .context,
                    bundleID: "us.zoom.xos",
                    payload: payload
                ))
        }
        return events
    }
}
