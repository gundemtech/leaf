import XCTest
@testable import LeafCore

final class ZoomMeetingDurationTrackerTests: XCTestCase {

    // MARK: - Cold-start

    func testColdStartEmitsImmediately() {
        var t = ZoomMeetingDurationTracker(
            thresholds: .testing,
            calendarLinker: NoOpZoomCalendarLinker()
        )
        let obs = ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: nil)
        let events = t.observe(obs, nowMs: 1000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["event_kind"], "zoom_meeting_started")
        XCTAssertEqual(events[0].payload["cold_start"], "true")
        XCTAssertEqual(events[0].payload["started_at_ms"], "1000")
    }

    func testColdStartNotInMeetingNoEmit() {
        var t = ZoomMeetingDurationTracker(
            thresholds: .testing,
            calendarLinker: NoOpZoomCalendarLinker()
        )
        let obs = ZoomObservation(meetingState: .notInMeeting, ownMeetingTopic: nil)
        let events = t.observe(obs, nowMs: 1000)
        XCTAssertEqual(events.count, 0)
    }

    // MARK: - Warm-start GRACE_START

    func testWarmStartPendingThenActiveAfterGrace() {
        var t = ZoomMeetingDurationTracker(
            thresholds: .init(graceStartMs: 5_000, graceEndMs: 30_000),
            calendarLinker: NoOpZoomCalendarLinker()
        )
        _ = t.observe(ZoomObservation(meetingState: .notInMeeting, ownMeetingTopic: nil), nowMs: 1_000)
        let evt2 = t.observe(ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: nil), nowMs: 2_000)
        XCTAssertEqual(evt2.count, 0)
        let evt3 = t.observe(ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: nil), nowMs: 33_000)
        XCTAssertEqual(evt3.count, 1)
        XCTAssertEqual(evt3[0].payload["event_kind"], "zoom_meeting_started")
        XCTAssertEqual(evt3[0].payload["cold_start"], "false")
        XCTAssertEqual(evt3[0].payload["started_at_ms"], "2000")
    }

    func testWarmStartFalseAlarmRevertsToIdle() {
        var t = ZoomMeetingDurationTracker(
            thresholds: .init(graceStartMs: 5_000, graceEndMs: 30_000),
            calendarLinker: NoOpZoomCalendarLinker()
        )
        _ = t.observe(ZoomObservation(meetingState: .notInMeeting, ownMeetingTopic: nil), nowMs: 1_000)
        let evt2 = t.observe(ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: nil), nowMs: 2_000)
        XCTAssertEqual(evt2.count, 0)
        let evt3 = t.observe(ZoomObservation(meetingState: .notInMeeting, ownMeetingTopic: nil), nowMs: 3_000)
        XCTAssertEqual(evt3.count, 0)
        if case .idle = t.currentState { /* ok */ }
        else { XCTFail("Expected idle state after false alarm, got \(t.currentState)") }
    }

    // MARK: - GRACE_END

    func testActiveToEndedAfterGraceEnd() {
        var t = ZoomMeetingDurationTracker(
            thresholds: .init(graceStartMs: 5_000, graceEndMs: 30_000),
            calendarLinker: NoOpZoomCalendarLinker()
        )
        _ = t.observe(ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: nil), nowMs: 1_000)
        let evt2 = t.observe(ZoomObservation(meetingState: .notInMeeting, ownMeetingTopic: nil), nowMs: 2_000)
        XCTAssertEqual(evt2.count, 0)
        let evt3 = t.observe(ZoomObservation(meetingState: .notInMeeting, ownMeetingTopic: nil), nowMs: 33_000)
        XCTAssertEqual(evt3.count, 1)
        XCTAssertEqual(evt3[0].payload["event_kind"], "zoom_meeting_ended")
        XCTAssertEqual(evt3[0].payload["started_at_ms"], "1000")
        XCTAssertEqual(evt3[0].payload["ended_at_ms"], "2000")
        XCTAssertEqual(evt3[0].payload["duration_seconds"], "1")
        XCTAssertEqual(evt3[0].payload["cold_start_origin"], "true")
        XCTAssertEqual(evt3[0].payload["dropped_transitions_count"], "0")
    }

    func testPendingEndRevertsToActiveOnFlicker() {
        var t = ZoomMeetingDurationTracker(
            thresholds: .init(graceStartMs: 1, graceEndMs: 30_000),
            calendarLinker: NoOpZoomCalendarLinker()
        )
        _ = t.observe(ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: nil), nowMs: 1_000)
        let evt2 = t.observe(ZoomObservation(meetingState: .notInMeeting, ownMeetingTopic: nil), nowMs: 2_000)
        XCTAssertEqual(evt2.count, 0)
        let evt3 = t.observe(ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: nil), nowMs: 3_000)
        XCTAssertEqual(evt3.count, 0)
        if case .active = t.currentState { /* ok */ }
        else { XCTFail("Expected active state after revert, got \(t.currentState)") }
    }

    func testMultipleFlickersAccumulateDroppedCount() {
        var t = ZoomMeetingDurationTracker(
            thresholds: .init(graceStartMs: 1, graceEndMs: 30_000),
            calendarLinker: NoOpZoomCalendarLinker()
        )
        _ = t.observe(ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: nil), nowMs: 1_000)
        // Flicker 1.
        _ = t.observe(ZoomObservation(meetingState: .notInMeeting, ownMeetingTopic: nil), nowMs: 2_000)
        _ = t.observe(ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: nil), nowMs: 3_000)
        // Flicker 2.
        _ = t.observe(ZoomObservation(meetingState: .notInMeeting, ownMeetingTopic: nil), nowMs: 4_000)
        _ = t.observe(ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: nil), nowMs: 5_000)
        // Real end.
        _ = t.observe(ZoomObservation(meetingState: .notInMeeting, ownMeetingTopic: nil), nowMs: 6_000)
        let events = t.observe(ZoomObservation(meetingState: .notInMeeting, ownMeetingTopic: nil), nowMs: 40_000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["dropped_transitions_count"], "2",
                       "Expected 2 dropped transitions from flickers; got \(events[0].payload["dropped_transitions_count"] ?? "nil")")
    }

    // MARK: - Calendar linker

    private struct FixedLinker: ZoomCalendarLinker {
        let hash: String?
        func match(atMs: Int64) -> String? { hash }
    }

    func testColdStartWithCalendarMatchEmitsLinkedEvent() {
        var t = ZoomMeetingDurationTracker(
            thresholds: .testing,
            calendarLinker: FixedLinker(hash: "deadbeefcafef00d")
        )
        let events = t.observe(ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: nil), nowMs: 1_000)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].payload["event_kind"], "zoom_meeting_started")
        XCTAssertEqual(events[0].payload["linked_calendar_event_id"], "deadbeefcafef00d")
        XCTAssertEqual(events[1].payload["event_kind"], "zoom_meeting_calendar_linked")
        XCTAssertEqual(events[1].payload["linked_calendar_event_id"], "deadbeefcafef00d")
        XCTAssertEqual(events[1].payload["calendar_source"], "eventkit")
        XCTAssertEqual(events[1].payload["match_method"], "url_regex_eventkit")
        XCTAssertEqual(events[1].payload["confidence"], "0.95")
    }

    func testColdStartWithNoCalendarMatchEmitsOnlyStartedEvent() {
        var t = ZoomMeetingDurationTracker(
            thresholds: .testing,
            calendarLinker: FixedLinker(hash: nil)
        )
        let events = t.observe(ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: nil), nowMs: 1_000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["event_kind"], "zoom_meeting_started")
        XCTAssertEqual(events[0].payload["linked_calendar_event_id"], "")
    }

    func testEndedEventCarriesLinkedCalEventIDFromActiveState() {
        var t = ZoomMeetingDurationTracker(
            thresholds: .testing,
            calendarLinker: FixedLinker(hash: "abc123def456")
        )
        _ = t.observe(ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: nil), nowMs: 1_000)
        _ = t.observe(ZoomObservation(meetingState: .notInMeeting, ownMeetingTopic: nil), nowMs: 2_000)
        let events = t.observe(ZoomObservation(meetingState: .notInMeeting, ownMeetingTopic: nil), nowMs: 3_000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["event_kind"], "zoom_meeting_ended")
        XCTAssertEqual(events[0].payload["linked_calendar_event_id"], "abc123def456")
    }

    // MARK: - Non-default meeting states

    func testWaitingRoomCountsAsMeetingActive() {
        var t = ZoomMeetingDurationTracker(thresholds: .testing, calendarLinker: NoOpZoomCalendarLinker())
        let events = t.observe(ZoomObservation(meetingState: .waitingRoom, ownMeetingTopic: nil), nowMs: 1_000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["event_kind"], "zoom_meeting_started")
    }

    func testScreenSharingCountsAsMeetingActive() {
        var t = ZoomMeetingDurationTracker(thresholds: .testing, calendarLinker: NoOpZoomCalendarLinker())
        let events = t.observe(ZoomObservation(meetingState: .screenSharing, ownMeetingTopic: nil), nowMs: 1_000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["event_kind"], "zoom_meeting_started")
    }

    func testTransitionsBetweenMeetingActiveStatesNoEnd() {
        var t = ZoomMeetingDurationTracker(thresholds: .testing, calendarLinker: NoOpZoomCalendarLinker())
        _ = t.observe(ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: nil), nowMs: 1_000)
        let evt2 = t.observe(ZoomObservation(meetingState: .screenSharing, ownMeetingTopic: nil), nowMs: 2_000)
        XCTAssertEqual(evt2.count, 0)
        let evt3 = t.observe(ZoomObservation(meetingState: .waitingRoom, ownMeetingTopic: nil), nowMs: 3_000)
        XCTAssertEqual(evt3.count, 0)
    }

    // MARK: - Multi-session sequence

    func testTwoSessionsSequence() {
        var t = ZoomMeetingDurationTracker(thresholds: .testing, calendarLinker: NoOpZoomCalendarLinker())
        // Session 1: cold-start + end.
        _ = t.observe(ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: nil), nowMs: 1_000)
        _ = t.observe(ZoomObservation(meetingState: .notInMeeting, ownMeetingTopic: nil), nowMs: 2_000)
        let end1 = t.observe(ZoomObservation(meetingState: .notInMeeting, ownMeetingTopic: nil), nowMs: 3_000)
        XCTAssertEqual(end1.count, 1)
        XCTAssertEqual(end1[0].payload["event_kind"], "zoom_meeting_ended")
        // Session 2: warm-start (prev != nil now).
        let start2 = t.observe(ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: nil), nowMs: 10_000)
        XCTAssertEqual(start2.count, 0)  // pendingStart
        let start2confirmed = t.observe(ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: nil), nowMs: 10_500)
        XCTAssertEqual(start2confirmed.count, 1)
        XCTAssertEqual(start2confirmed[0].payload["event_kind"], "zoom_meeting_started")
        XCTAssertEqual(start2confirmed[0].payload["cold_start"], "false")
        XCTAssertEqual(start2confirmed[0].payload["started_at_ms"], "10000")
    }
}
