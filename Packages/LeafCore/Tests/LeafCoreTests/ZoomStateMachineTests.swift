import XCTest

@testable import LeafCore

final class ZoomStateMachineTests: XCTestCase {
    func testFirstObservationEmitsState() {
        var sm = ZoomStateMachine()
        let events = sm.observe(
            ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: nil), nowMs: 1000, meetingTopicOptedIn: false)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["event_kind"], "zoom_meeting_state_changed")
        XCTAssertEqual(events[0].payload["meeting_state"], "in_meeting")
    }

    func testStateChangeEmitsStateEvent() {
        var sm = ZoomStateMachine()
        _ = sm.observe(
            ZoomObservation(meetingState: .notInMeeting, ownMeetingTopic: nil), nowMs: 1000, meetingTopicOptedIn: false)
        let events = sm.observe(
            ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: nil), nowMs: 2000, meetingTopicOptedIn: false)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["meeting_state"], "in_meeting")
    }

    func testSubFieldOptInGatesTopicEmission() {
        // First observation with topic but opted out → only state event emits.
        var sm = ZoomStateMachine()
        let events = sm.observe(
            ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: "Q1 review"), nowMs: 1000,
            meetingTopicOptedIn: false)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["event_kind"], "zoom_meeting_state_changed")
    }

    func testWithOptInTopicAndStateEmit() {
        var sm = ZoomStateMachine()
        let events = sm.observe(
            ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: "Q1 review"), nowMs: 1000,
            meetingTopicOptedIn: true)
        XCTAssertEqual(events.count, 2)
        let kinds = Set(events.compactMap { $0.payload["event_kind"] })
        XCTAssertEqual(kinds, ["zoom_meeting_state_changed", "zoom_meeting_name_observed"])
        XCTAssertEqual(
            events.first(where: { $0.payload["event_kind"] == "zoom_meeting_name_observed" })?.payload["meeting_topic"],
            "Q1 review")
    }

    func testIdempotentEmitsNothing() {
        var sm = ZoomStateMachine()
        let obs = ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: "Q1")
        _ = sm.observe(obs, nowMs: 1000, meetingTopicOptedIn: true)
        XCTAssertEqual(sm.observe(obs, nowMs: 2000, meetingTopicOptedIn: true).count, 0)
    }

    func testPayloadHasNoAttendeesOrPasswordFields() {
        var sm = ZoomStateMachine()
        let events = sm.observe(
            ZoomObservation(meetingState: .inMeeting, ownMeetingTopic: "T"), nowMs: 1000, meetingTopicOptedIn: true)
        for ev in events {
            XCTAssertNil(ev.payload["participants"])
            XCTAssertNil(ev.payload["attendees"])
            XCTAssertNil(ev.payload["password"])
        }
    }
}
