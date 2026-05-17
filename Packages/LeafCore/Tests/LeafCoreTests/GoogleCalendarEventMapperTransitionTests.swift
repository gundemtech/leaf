import XCTest

@testable import LeafCore

// swiftlint:disable force_unwrapping
// Reason: test fixtures rely on force-unwrap for setup convenience —
// JSON decoding, post-`try` payload reads where nil ⇒ broken test.

/// Track-6 P4 Task 7 — `GoogleCalendarEventMapper.makeTransitionPayload` tests.
/// Split from GoogleCalendarEventMapperTests for type_body_length / file_length.
final class GoogleCalendarEventMapperTransitionTests: XCTestCase {

    /// Forbidden output keys (ADR-010, spec §6.4). Asserted to NOT appear in
    /// payload dict regardless of source data presence.
    private let forbiddenKeys: [String] = [
        "description",
        "location",
        "attendee_email",
        "attendees",
        "organizer_email",
        "creator_email",
        "html_link",
        "htmlLink",
        "hangout_link",
        "hangoutLink",
        "conference_uri",
        "conference_passcode",
        "conference_pin",
        "conference_meeting_code",
        "decline_message",
        "declineMessage",
        "building_id",
        "buildingId",
        "floor_id",
        "desk_id",
        "office_label",
        "custom_location_label",
        "extended_properties",
        "attachments",
    ]

    private func assertNoForbiddenKeys(
        _ payload: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for key in forbiddenKeys {
            XCTAssertNil(
                payload[key],
                "Forbidden key '\(key)' leaked into payload",
                file: file,
                line: line
            )
        }
    }

    private func decode(_ json: String) throws -> GoogleCalendarAPI.Event {
        try JSONDecoder().decode(GoogleCalendarAPI.Event.self, from: json.data(using: .utf8)!)
    }

    /// Belt-and-suspenders raw-JSON walkback — serialises the payload and
    /// asserts that no sentinel string from the source event leaked through.
    private func assertJSONDoesNotContain(
        _ payload: [String: Any],
        _ needles: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let text = String(data: data, encoding: .utf8) ?? ""
        for needle in needles {
            XCTAssertFalse(
                text.contains(needle),
                "Forbidden substring '\(needle)' leaked into payload JSON: \(text)",
                file: file,
                line: line
            )
        }
    }

    func testFocusBlockStartedPayloadCarriesAutoDeclineAndChatStatus() throws {
        let json = """
            {
              "id": "focus-evt-1",
              "iCalUID": "focus-evt-1@google.com",
              "status": "confirmed",
              "summary": "Deep work",
              "start": {"dateTime": "2026-05-16T14:00:00+02:00", "timeZone": "Europe/Berlin"},
              "end":   {"dateTime": "2026-05-16T16:00:00+02:00", "timeZone": "Europe/Berlin"},
              "eventType": "focusTime",
              "focusTimeProperties": {
                "autoDeclineMode": "declineAllConflictingInvitations",
                "declineMessage": "SECRET-SHOULD-NOT-LEAK",
                "chatStatus": "doNotDisturb"
              }
            }
            """
        let event = try decode(json)
        let payload = try XCTUnwrap(
            GoogleCalendarEventMapper.makeTransitionPayload(
                event: event,
                phase: .started,
                calendarId: "me@example.com"
            ))
        XCTAssertEqual(payload["source"] as? String, "google_calendar")
        XCTAssertEqual(payload["event_kind"] as? String, "google_calendar_focus_block_started")
        XCTAssertEqual(payload["event_id"] as? String, "focus-evt-1")
        XCTAssertEqual(payload["i_cal_uid"] as? String, "focus-evt-1@google.com")
        XCTAssertEqual(payload["calendar_id"] as? String, "me@example.com")
        XCTAssertNotNil(payload["start_ms"])
        XCTAssertNotNil(payload["end_ms"])
        XCTAssertEqual(payload["auto_decline_mode"] as? String, "declineAllConflictingInvitations")
        XCTAssertEqual(payload["chat_status"] as? String, "doNotDisturb")
        // Privacy walkbacks
        XCTAssertNil(payload["decline_message"])
        XCTAssertNil(payload["declineMessage"])
        assertNoForbiddenKeys(payload)
        try assertJSONDoesNotContain(payload, ["SECRET-SHOULD-NOT-LEAK"])
    }

    func testFocusBlockEndedPayloadHasNoAutoDeclineOrChatStatus() throws {
        let json = """
            {
              "id": "focus-evt-1",
              "iCalUID": "focus-evt-1@google.com",
              "status": "confirmed",
              "summary": "Deep work",
              "start": {"dateTime": "2026-05-16T14:00:00+02:00", "timeZone": "Europe/Berlin"},
              "end":   {"dateTime": "2026-05-16T16:00:00+02:00", "timeZone": "Europe/Berlin"},
              "eventType": "focusTime",
              "focusTimeProperties": {
                "autoDeclineMode": "declineAllConflictingInvitations",
                "declineMessage": "SECRET-SHOULD-NOT-LEAK",
                "chatStatus": "doNotDisturb"
              }
            }
            """
        let event = try decode(json)
        let payload = try XCTUnwrap(
            GoogleCalendarEventMapper.makeTransitionPayload(
                event: event,
                phase: .ended,
                calendarId: "me@example.com"
            ))
        XCTAssertEqual(payload["event_kind"] as? String, "google_calendar_focus_block_ended")
        XCTAssertEqual(payload["event_id"] as? String, "focus-evt-1")
        XCTAssertEqual(payload["i_cal_uid"] as? String, "focus-evt-1@google.com")
        XCTAssertEqual(payload["calendar_id"] as? String, "me@example.com")
        XCTAssertNotNil(payload["start_ms"])
        XCTAssertNotNil(payload["end_ms"])
        // Operational fields are active-phase only; absent on _ended.
        XCTAssertNil(payload["auto_decline_mode"])
        XCTAssertNil(payload["chat_status"])
        assertNoForbiddenKeys(payload)
        try assertJSONDoesNotContain(payload, ["SECRET-SHOULD-NOT-LEAK"])
    }

    func testOOOStartedPayloadCarriesAutoDeclineNoChatStatusNoDeclineMessage() throws {
        let json = """
            {
              "id": "ooo-evt-1",
              "iCalUID": "ooo-evt-1@google.com",
              "status": "confirmed",
              "summary": "OOO",
              "start": {"dateTime": "2026-05-20T00:00:00+02:00", "timeZone": "Europe/Berlin"},
              "end":   {"dateTime": "2026-05-22T00:00:00+02:00", "timeZone": "Europe/Berlin"},
              "eventType": "outOfOffice",
              "outOfOfficeProperties": {
                "autoDeclineMode": "declineOnlyNewConflictingInvitations",
                "declineMessage": "SECRET-OOO-MESSAGE"
              }
            }
            """
        let event = try decode(json)
        let payload = try XCTUnwrap(
            GoogleCalendarEventMapper.makeTransitionPayload(
                event: event,
                phase: .started,
                calendarId: "me@example.com"
            ))
        XCTAssertEqual(payload["event_kind"] as? String, "google_calendar_ooo_started")
        XCTAssertEqual(payload["event_id"] as? String, "ooo-evt-1")
        XCTAssertEqual(payload["i_cal_uid"] as? String, "ooo-evt-1@google.com")
        XCTAssertEqual(payload["auto_decline_mode"] as? String, "declineOnlyNewConflictingInvitations")
        // OOO never has chat_status (Google API contract).
        XCTAssertNil(payload["chat_status"])
        XCTAssertNil(payload["decline_message"])
        XCTAssertNil(payload["declineMessage"])
        assertNoForbiddenKeys(payload)
        try assertJSONDoesNotContain(payload, ["SECRET-OOO-MESSAGE"])
    }

    func testOOOEndedPayloadHasNoAutoDecline() throws {
        let json = """
            {
              "id": "ooo-evt-1",
              "iCalUID": "ooo-evt-1@google.com",
              "status": "confirmed",
              "summary": "OOO",
              "start": {"dateTime": "2026-05-20T00:00:00+02:00", "timeZone": "Europe/Berlin"},
              "end":   {"dateTime": "2026-05-22T00:00:00+02:00", "timeZone": "Europe/Berlin"},
              "eventType": "outOfOffice",
              "outOfOfficeProperties": {
                "autoDeclineMode": "declineAllConflictingInvitations",
                "declineMessage": "SECRET-OOO-MESSAGE"
              }
            }
            """
        let event = try decode(json)
        let payload = try XCTUnwrap(
            GoogleCalendarEventMapper.makeTransitionPayload(
                event: event,
                phase: .ended,
                calendarId: "me@example.com"
            ))
        XCTAssertEqual(payload["event_kind"] as? String, "google_calendar_ooo_ended")
        XCTAssertEqual(payload["event_id"] as? String, "ooo-evt-1")
        XCTAssertNotNil(payload["start_ms"])
        XCTAssertNotNil(payload["end_ms"])
        XCTAssertNil(payload["auto_decline_mode"])
        XCTAssertNil(payload["chat_status"])
        assertNoForbiddenKeys(payload)
        try assertJSONDoesNotContain(payload, ["SECRET-OOO-MESSAGE"])
    }

    func testWorkingLocationChangedPayloadHasTypeBucketNoBuildingId() throws {
        // Source JSON has officeLocation.{buildingId,floorId,deskId,label} —
        // Codable doesn't even decode them (privacy posture). Mapper output
        // re-asserted clean as defence-in-depth.
        let json = """
            {
              "id": "wl-evt-1",
              "status": "confirmed",
              "summary": "In office",
              "start": {"date": "2026-05-16"},
              "end":   {"date": "2026-05-17"},
              "eventType": "workingLocation",
              "workingLocationProperties": {
                "type": "homeOffice",
                "officeLocation": {
                  "buildingId": "BERLIN-HQ-3",
                  "floorId": "F4",
                  "deskId": "D17",
                  "label": "Window seat"
                },
                "customLocation": {"label": "SECRET-LOCATION-LABEL"}
              }
            }
            """
        let event = try decode(json)
        let payload = try XCTUnwrap(
            GoogleCalendarEventMapper.makeTransitionPayload(
                event: event,
                phase: .changed,
                calendarId: "me@example.com"
            ))
        XCTAssertEqual(payload["event_kind"] as? String, "google_calendar_working_location_changed")
        XCTAssertEqual(payload["event_id"] as? String, "wl-evt-1")
        XCTAssertEqual(payload["working_location_type"] as? String, "homeOffice")
        XCTAssertNotNil(payload["start_ms"])
        XCTAssertNotNil(payload["end_ms"])
        // Forbidden physical-location fields
        XCTAssertNil(payload["building_id"])
        XCTAssertNil(payload["buildingId"])
        XCTAssertNil(payload["floor_id"])
        XCTAssertNil(payload["desk_id"])
        XCTAssertNil(payload["office_label"])
        XCTAssertNil(payload["custom_location_label"])
        assertNoForbiddenKeys(payload)
        try assertJSONDoesNotContain(
            payload,
            [
                "BERLIN-HQ-3", "F4", "D17", "Window seat", "SECRET-LOCATION-LABEL",
            ])
    }

    func testInvalidTransitionCombinationReturnsNil() throws {
        // (default, .started) is not a transition.
        let defaultJSON = """
            {
              "id": "evt1",
              "status": "confirmed",
              "summary": "Standup",
              "start": {"dateTime": "2026-05-16T09:00:00+02:00", "timeZone": "Europe/Berlin"},
              "end":   {"dateTime": "2026-05-16T09:30:00+02:00", "timeZone": "Europe/Berlin"},
              "eventType": "default"
            }
            """
        let defaultEvent = try decode(defaultJSON)
        XCTAssertNil(
            GoogleCalendarEventMapper.makeTransitionPayload(
                event: defaultEvent,
                phase: .started,
                calendarId: "me@example.com"
            ))

        // workingLocation + .ended is not a valid pair (single-shot `.changed`).
        let wlJSON = """
            {
              "id": "wl1",
              "status": "confirmed",
              "summary": "In office",
              "start": {"date": "2026-05-16"},
              "end":   {"date": "2026-05-17"},
              "eventType": "workingLocation",
              "workingLocationProperties": {"type": "homeOffice"}
            }
            """
        let wlEvent = try decode(wlJSON)
        XCTAssertNil(
            GoogleCalendarEventMapper.makeTransitionPayload(
                event: wlEvent,
                phase: .ended,
                calendarId: "me@example.com"
            ))
        // focusTime + .changed also invalid.
        let focusJSON = """
            {
              "id": "focus1",
              "status": "confirmed",
              "summary": "Deep work",
              "start": {"dateTime": "2026-05-16T14:00:00+02:00", "timeZone": "Europe/Berlin"},
              "end":   {"dateTime": "2026-05-16T16:00:00+02:00", "timeZone": "Europe/Berlin"},
              "eventType": "focusTime"
            }
            """
        let focusEvent = try decode(focusJSON)
        XCTAssertNil(
            GoogleCalendarEventMapper.makeTransitionPayload(
                event: focusEvent,
                phase: .changed,
                calendarId: "me@example.com"
            ))
    }

    func testMissingEventTypeReturnsNil() throws {
        // No eventType field → defensive nil (transitions need explicit type).
        let json = """
            {
              "id": "evt1",
              "status": "confirmed",
              "summary": "Untyped",
              "start": {"dateTime": "2026-05-16T09:00:00+02:00", "timeZone": "Europe/Berlin"},
              "end":   {"dateTime": "2026-05-16T09:30:00+02:00", "timeZone": "Europe/Berlin"}
            }
            """
        let event = try decode(json)
        XCTAssertNil(
            GoogleCalendarEventMapper.makeTransitionPayload(
                event: event,
                phase: .started,
                calendarId: "me@example.com"
            ))
    }
}
// swiftlint:enable force_unwrapping
