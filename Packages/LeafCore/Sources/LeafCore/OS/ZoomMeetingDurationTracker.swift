import Foundation

/// Phase Track-6 P5 — Pure coalescing state machine that layers on top of
/// ZoomStateMachine. Consumes the same ZoomObservation stream and emits
/// `zoom_meeting_started` / `zoom_meeting_ended` / `zoom_meeting_calendar_linked`
/// events with timestamps, cold-start flag, and dropped-transitions counter.
///
/// Coalescer thresholds (GRACE_START, GRACE_END) are moat-tuned constants
/// passed via `Thresholds`. Public `.testing` default uses 1ms for fast tests;
/// production injection lives in LeafCorePrivate.
public struct ZoomMeetingDurationTracker: Sendable {

    public struct Thresholds: Sendable, Hashable {
        public let graceStartMs: Int64
        public let graceEndMs: Int64

        public init(graceStartMs: Int64, graceEndMs: Int64) {
            self.graceStartMs = graceStartMs
            self.graceEndMs = graceEndMs
        }

        /// Test default — 1ms grace = effectively no debounce.
        public static let testing = Self(graceStartMs: 1, graceEndMs: 1)
    }

    public enum State: Sendable, Hashable {
        case idle
        case pendingStart(observedAt: Int64)
        case active(startedAt: Int64, coldStart: Bool, linkedCalEventID: String?, droppedTransitionsSoFar: Int)
        case pendingEnd(
            startedAt: Int64, observedAt: Int64, coldStart: Bool, linkedCalEventID: String?, droppedTransitions: Int)
    }

    private let thresholds: Thresholds
    private let calendarLinker: any ZoomCalendarLinker
    private var state: State = .idle
    private var prev: ZoomObservation?

    public init(thresholds: Thresholds, calendarLinker: any ZoomCalendarLinker) {
        self.thresholds = thresholds
        self.calendarLinker = calendarLinker
    }

    private static func isMeetingActive(_ s: ZoomMeetingState) -> Bool {
        switch s {
        case .notInMeeting: return false
        case .inMeeting, .waitingRoom, .screenSharing: return true
        }
    }

    public mutating func observe(_ obs: ZoomObservation, nowMs: Int64) -> [RawEvent] {
        defer { prev = obs }
        let meetingActive = Self.isMeetingActive(obs.meetingState)
        var events: [RawEvent] = []

        switch state {
        case .idle:
            if meetingActive {
                if prev == nil {
                    // Cold-start path — emit immediately with cold_start=true.
                    let linkedID = calendarLinker.match(atMs: nowMs)
                    state = .active(
                        startedAt: nowMs,
                        coldStart: true,
                        linkedCalEventID: linkedID,
                        droppedTransitionsSoFar: 0
                    )
                    events.append(makeStartedEvent(startedAtMs: nowMs, coldStart: true, linkedCalEventID: linkedID))
                    if let id = linkedID {
                        events.append(makeCalendarLinkedEvent(startedAtMs: nowMs, linkedCalEventID: id))
                    }
                } else {
                    // Warm-start path — enter pendingStart.
                    state = .pendingStart(observedAt: nowMs)
                }
            }
        // else: idle stays idle.

        case .pendingStart(let observedAt):
            if meetingActive {
                if nowMs - observedAt >= thresholds.graceStartMs {
                    let linkedID = calendarLinker.match(atMs: observedAt)
                    state = .active(
                        startedAt: observedAt,
                        coldStart: false,
                        linkedCalEventID: linkedID,
                        droppedTransitionsSoFar: 0
                    )
                    events.append(
                        makeStartedEvent(startedAtMs: observedAt, coldStart: false, linkedCalEventID: linkedID))
                    if let id = linkedID {
                        events.append(makeCalendarLinkedEvent(startedAtMs: observedAt, linkedCalEventID: id))
                    }
                }
                // else: still in pendingStart.
            } else {
                // False alarm — revert to idle, no emit.
                state = .idle
            }

        case .active(let startedAt, let coldStart, let linkedCalEventID, let droppedSoFar):
            if !meetingActive {
                state = .pendingEnd(
                    startedAt: startedAt,
                    observedAt: nowMs,
                    coldStart: coldStart,
                    linkedCalEventID: linkedCalEventID,
                    droppedTransitions: droppedSoFar
                )
            }
        // else: still active.

        case .pendingEnd(let startedAt, let observedAt, let coldStart, let linkedCalEventID, let dropped):
            if meetingActive {
                // Revert to active. Increment dropped counter, preserved for next pendingEnd cycle.
                state = .active(
                    startedAt: startedAt,
                    coldStart: coldStart,
                    linkedCalEventID: linkedCalEventID,
                    droppedTransitionsSoFar: dropped + 1
                )
            } else {
                if nowMs - observedAt >= thresholds.graceEndMs {
                    let durationSec = (observedAt - startedAt) / 1000
                    events.append(
                        makeEndedEvent(
                            startedAtMs: startedAt,
                            endedAtMs: observedAt,
                            durationSeconds: durationSec,
                            coldStartOrigin: coldStart,
                            droppedTransitionsCount: dropped,
                            linkedCalEventID: linkedCalEventID
                        ))
                    state = .idle
                }
                // else: still in pendingEnd.
            }
        }

        return events
    }

    public var currentState: State { state }

    // MARK: - RawEvent builders

    private func makeStartedEvent(startedAtMs: Int64, coldStart: Bool, linkedCalEventID: String?) -> RawEvent {
        let payload: [String: String] = [
            "source": "zoom",
            "event_kind": "zoom_meeting_started",
            "started_at_ms": String(startedAtMs),
            "cold_start": coldStart ? "true" : "false",
            "linked_calendar_event_id": linkedCalEventID ?? "",
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: Double(startedAtMs) / 1000.0),
            signalType: .context,
            bundleID: "us.zoom.xos",
            payload: payload
        )
    }

    private func makeEndedEvent(
        startedAtMs: Int64,
        endedAtMs: Int64,
        durationSeconds: Int64,
        coldStartOrigin: Bool,
        droppedTransitionsCount: Int,
        linkedCalEventID: String?
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "zoom",
            "event_kind": "zoom_meeting_ended",
            "started_at_ms": String(startedAtMs),
            "ended_at_ms": String(endedAtMs),
            "duration_seconds": String(durationSeconds),
            "cold_start_origin": coldStartOrigin ? "true" : "false",
            "dropped_transitions_count": String(droppedTransitionsCount),
            "linked_calendar_event_id": linkedCalEventID ?? "",
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: Double(endedAtMs) / 1000.0),
            signalType: .context,
            bundleID: "us.zoom.xos",
            payload: payload
        )
    }

    private func makeCalendarLinkedEvent(startedAtMs: Int64, linkedCalEventID: String) -> RawEvent {
        let payload: [String: String] = [
            "source": "zoom",
            "event_kind": "zoom_meeting_calendar_linked",
            "started_at_ms": String(startedAtMs),
            "linked_calendar_event_id": linkedCalEventID,
            "calendar_source": "eventkit",
            "match_method": "url_regex_eventkit",
            "confidence": "0.95",
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: Double(startedAtMs) / 1000.0),
            signalType: .context,
            bundleID: "us.zoom.xos",
            payload: payload
        )
    }
}
