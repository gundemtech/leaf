import XCTest

@testable import LeafCore

// swiftlint:disable force_unwrapping
// Reason: test fixtures rely on force-unwrap for setup convenience —
// URL literals, HTTPURLResponse construction, decoded JSON, post-`try`
// DB reads where nil ⇒ broken test, not production semantic.

/// Track-6 P4 Task 6 — `GoogleCalendarEventMapper.makeObservedPayload` tests.
///
/// Coverage matrix:
/// 1-4. event_type buckets (default / focusTime / outOfOffice / workingLocation)
///      + per-type forbidden-key walkbacks (declineMessage, buildingId, …).
/// 5-6. cancelled instance + recurring instance.
/// 7. all-day event (`start.date` shape).
/// 8. conferenceData → entry/solution buckets (uri NEVER in output).
/// 9. external attendee counting across multi-domain set.
/// 10. unknown eventType graceful-degrades to "other".
/// 11. nil attendees → zero counts.
/// 12. timezone passthrough.
///
/// Transition-payload tests live in GoogleCalendarEventMapperTransitionTests.swift.
final class GoogleCalendarEventMapperTests: XCTestCase {

    // MARK: - Helpers

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

    private let calendarOwner = GoogleCalendarSyncTokenStore.KnownCalendar(
        id: "me@example.com",
        summary: "primary",
        summaryOverride: nil,
        accessRole: "owner",
        primary: true,
        colorId: nil,
        timeZone: "Europe/Berlin"
    )

    private func decode(_ json: String) throws -> GoogleCalendarAPI.Event {
        try JSONDecoder().decode(GoogleCalendarAPI.Event.self, from: json.data(using: .utf8)!)
    }

    // MARK: - Tests

    func testDefaultEventWithAttendeesMapsCleanly() throws {
        let json = """
            {
              "id": "evt1",
              "iCalUID": "evt1@google.com",
              "status": "confirmed",
              "summary": "Standup",
              "description": "Daily team sync — remember the design doc",
              "location": "HQ Room 5B",
              "start": {"dateTime": "2026-05-16T09:00:00+02:00", "timeZone": "Europe/Berlin"},
              "end":   {"dateTime": "2026-05-16T09:30:00+02:00", "timeZone": "Europe/Berlin"},
              "eventType": "default",
              "transparency": "opaque",
              "visibility": "default",
              "attendees": [
                {"email":"me@example.com","self":true,"responseStatus":"accepted","organizer":true},
                {"email":"ext@other.com","responseStatus":"needsAction"}
              ],
              "organizer": {"email":"me@example.com","self":true},
              "creator":   {"email":"me@example.com","self":true},
              "htmlLink": "https://calendar.google.com/event?eid=abc",
              "created": "2026-05-01T00:00:00.000Z",
              "updated": "2026-05-15T00:00:00.000Z"
            }
            """
        let event = try decode(json)
        let payload = try XCTUnwrap(
            GoogleCalendarEventMapper.makeObservedPayload(
                event,
                calendar: calendarOwner,
                userDomain: "example.com"
            ))

        XCTAssertEqual(payload["source"] as? String, "google_calendar")
        XCTAssertEqual(payload["event_kind"] as? String, "google_calendar_event_observed")
        XCTAssertEqual(payload["event_id"] as? String, "evt1")
        XCTAssertEqual(payload["i_cal_uid"] as? String, "evt1@google.com")
        XCTAssertEqual(payload["calendar_id"] as? String, "me@example.com")
        XCTAssertEqual(payload["calendar_access_role"] as? String, "owner")
        XCTAssertEqual(payload["status"] as? String, "confirmed")
        XCTAssertEqual(payload["summary"] as? String, "Standup")
        XCTAssertEqual(payload["event_type"] as? String, "default")
        XCTAssertEqual(payload["is_all_day"] as? Bool, false)
        XCTAssertEqual(payload["timezone"] as? String, "Europe/Berlin")
        XCTAssertEqual(payload["transparency"] as? String, "opaque")
        XCTAssertEqual(payload["visibility"] as? String, "default")
        XCTAssertEqual(payload["attendees_count"] as? Int, 2)
        XCTAssertEqual(payload["external_attendee_count"] as? Int, 1)
        XCTAssertEqual(payload["self_response_status"] as? String, "accepted")
        XCTAssertEqual(payload["self_is_organizer"] as? Bool, true)
        XCTAssertEqual(payload["self_is_creator"] as? Bool, true)
        XCTAssertEqual(payload["is_recurring_instance"] as? Bool, false)
        XCTAssertEqual(payload["recurrence_frequency_bucket"] as? String, "one_off")
        XCTAssertEqual(payload["conference_entry_point_type"] as? String, "none")
        XCTAssertEqual(payload["conference_solution_type"] as? String, "none")
        XCTAssertNotNil(payload["created_ms"])
        XCTAssertNotNil(payload["updated_ms"])

        assertNoForbiddenKeys(payload)
    }

    func testFocusTimeEventMapsEventType() throws {
        let json = """
            {
              "id": "focus1",
              "status": "confirmed",
              "summary": "Deep work",
              "start": {"dateTime": "2026-05-16T14:00:00+02:00", "timeZone": "Europe/Berlin"},
              "end":   {"dateTime": "2026-05-16T16:00:00+02:00", "timeZone": "Europe/Berlin"},
              "eventType": "focusTime",
              "focusTimeProperties": {
                "autoDeclineMode": "declineAllConflictingInvitations",
                "declineMessage": "I'm heads-down — try after 4pm",
                "chatStatus": "doNotDisturb"
              }
            }
            """
        let event = try decode(json)
        let payload = try XCTUnwrap(
            GoogleCalendarEventMapper.makeObservedPayload(
                event,
                calendar: calendarOwner,
                userDomain: "example.com"
            ))
        XCTAssertEqual(payload["event_type"] as? String, "focusTime")
        assertNoForbiddenKeys(payload)
    }

    func testOOOEventDropsDeclineMessage() throws {
        let json = """
            {
              "id": "ooo1",
              "status": "confirmed",
              "summary": "OOO",
              "start": {"dateTime": "2026-05-20T00:00:00+02:00", "timeZone": "Europe/Berlin"},
              "end":   {"dateTime": "2026-05-22T00:00:00+02:00", "timeZone": "Europe/Berlin"},
              "eventType": "outOfOffice",
              "outOfOfficeProperties": {
                "autoDeclineMode": "declineAllConflictingInvitations",
                "declineMessage": "Out — back Monday"
              }
            }
            """
        let event = try decode(json)
        let payload = try XCTUnwrap(
            GoogleCalendarEventMapper.makeObservedPayload(
                event,
                calendar: calendarOwner,
                userDomain: "example.com"
            ))
        XCTAssertEqual(payload["event_type"] as? String, "outOfOffice")
        assertNoForbiddenKeys(payload)
    }

    func testWorkingLocationEventDropsBuildingId() throws {
        // Source JSON contains `officeLocation.buildingId` — Codable doesn't
        // even decode it (privacy posture in GoogleCalendarAPI.swift), but we
        // re-assert the output dict here as defence-in-depth.
        let json = """
            {
              "id": "wl1",
              "status": "confirmed",
              "summary": "In office",
              "start": {"date": "2026-05-16"},
              "end":   {"date": "2026-05-17"},
              "eventType": "workingLocation",
              "workingLocationProperties": {
                "type": "officeLocation",
                "officeLocation": {
                  "buildingId": "BERLIN-HQ-3",
                  "floorId": "F4",
                  "deskId": "D17",
                  "label": "Window seat"
                }
              }
            }
            """
        let event = try decode(json)
        let payload = try XCTUnwrap(
            GoogleCalendarEventMapper.makeObservedPayload(
                event,
                calendar: calendarOwner,
                userDomain: "example.com"
            ))
        XCTAssertEqual(payload["event_type"] as? String, "workingLocation")
        XCTAssertEqual(payload["is_all_day"] as? Bool, true)
        assertNoForbiddenKeys(payload)
    }

    func testCancelledInstanceMapsWithStatusCancelled() throws {
        let json = """
            {
              "id": "evt1_20260516T070000Z",
              "status": "cancelled",
              "recurringEventId": "evt1",
              "originalStartTime": {"dateTime": "2026-05-16T09:00:00+02:00", "timeZone": "Europe/Berlin"}
            }
            """
        let event = try decode(json)
        let payload = try XCTUnwrap(
            GoogleCalendarEventMapper.makeObservedPayload(
                event,
                calendar: calendarOwner,
                userDomain: "example.com"
            ))
        XCTAssertEqual(payload["status"] as? String, "cancelled")
        XCTAssertEqual(payload["is_recurring_instance"] as? Bool, true)
        // Limited cancelled-instance fields: no summary, no start/end.
        XCTAssertNil(payload["summary"])
        XCTAssertNil(payload["start_ms"])
        XCTAssertNil(payload["end_ms"])
        // event_type defaults to "default" when missing.
        XCTAssertEqual(payload["event_type"] as? String, "default")
        assertNoForbiddenKeys(payload)
    }

    func testRecurringWeeklyMapsRecurrenceBucket() throws {
        let json = """
            {
              "id": "rec1",
              "status": "confirmed",
              "summary": "Weekly sync",
              "start": {"dateTime": "2026-05-16T09:00:00+02:00", "timeZone": "Europe/Berlin"},
              "end":   {"dateTime": "2026-05-16T09:30:00+02:00", "timeZone": "Europe/Berlin"},
              "recurrence": ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"],
              "recurringEventId": "rec_master_1",
              "eventType": "default"
            }
            """
        let event = try decode(json)
        let payload = try XCTUnwrap(
            GoogleCalendarEventMapper.makeObservedPayload(
                event,
                calendar: calendarOwner,
                userDomain: "example.com"
            ))
        XCTAssertEqual(payload["recurrence_frequency_bucket"] as? String, "weekly")
        XCTAssertEqual(payload["is_recurring_instance"] as? Bool, true)
        assertNoForbiddenKeys(payload)
    }

    func testAllDayEventMapsIsAllDayTrue() throws {
        let json = """
            {
              "id": "allday1",
              "status": "confirmed",
              "summary": "Conference",
              "start": {"date": "2026-05-16"},
              "end":   {"date": "2026-05-17"},
              "eventType": "default"
            }
            """
        let event = try decode(json)
        let payload = try XCTUnwrap(
            GoogleCalendarEventMapper.makeObservedPayload(
                event,
                calendar: calendarOwner,
                userDomain: "example.com"
            ))
        XCTAssertEqual(payload["is_all_day"] as? Bool, true)
        // 2026-05-16 midnight UTC ms.
        let expectedStartMs: Int64 = {
            var comps = DateComponents()
            comps.year = 2026
            comps.month = 5
            comps.day = 16
            comps.hour = 0
            comps.minute = 0
            comps.second = 0
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            return Int64(cal.date(from: comps)!.timeIntervalSince1970 * 1000)
        }()
        XCTAssertEqual(payload["start_ms"] as? Int64, expectedStartMs)
        assertNoForbiddenKeys(payload)
    }

    func testConferenceDataMapsBuckets() throws {
        let json = """
            {
              "id": "conf1",
              "status": "confirmed",
              "summary": "Design review",
              "start": {"dateTime": "2026-05-16T10:00:00+02:00", "timeZone": "Europe/Berlin"},
              "end":   {"dateTime": "2026-05-16T11:00:00+02:00", "timeZone": "Europe/Berlin"},
              "eventType": "default",
              "conferenceData": {
                "entryPoints": [{"entryPointType":"video","uri":"https://meet.google.com/abc-def-ghi"}],
                "conferenceSolution":{"key":{"type":"hangoutsMeet"}}
              }
            }
            """
        let event = try decode(json)
        let payload = try XCTUnwrap(
            GoogleCalendarEventMapper.makeObservedPayload(
                event,
                calendar: calendarOwner,
                userDomain: "example.com"
            ))
        XCTAssertEqual(payload["conference_entry_point_type"] as? String, "video")
        XCTAssertEqual(payload["conference_solution_type"] as? String, "hangoutsMeet")
        assertNoForbiddenKeys(payload)
        // Belt-and-suspenders walkback: serialise to JSON and grep raw text.
        let json2 = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let text = String(data: json2, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("meet.google.com"), "Conference URI leaked into payload JSON")
        XCTAssertFalse(text.contains("abc-def-ghi"), "Conference code leaked into payload JSON")
    }

    func testExternalAttendeeCountWithMultiDomain() throws {
        let json = """
            {
              "id": "multi1",
              "status": "confirmed",
              "summary": "Cross-org sync",
              "start": {"dateTime": "2026-05-16T15:00:00+02:00", "timeZone": "Europe/Berlin"},
              "end":   {"dateTime": "2026-05-16T16:00:00+02:00", "timeZone": "Europe/Berlin"},
              "eventType": "default",
              "attendees": [
                {"email":"me@example.com","self":true,"responseStatus":"accepted"},
                {"email":"b@other.com","responseStatus":"accepted"},
                {"email":"c@third.org","responseStatus":"needsAction"}
              ]
            }
            """
        let event = try decode(json)
        let payload = try XCTUnwrap(
            GoogleCalendarEventMapper.makeObservedPayload(
                event,
                calendar: calendarOwner,
                userDomain: "example.com"
            ))
        XCTAssertEqual(payload["attendees_count"] as? Int, 3)
        XCTAssertEqual(payload["external_attendee_count"] as? Int, 2)
        assertNoForbiddenKeys(payload)
    }

    func testUnknownEventTypeMapsToOther() throws {
        let json = """
            {
              "id": "future1",
              "status": "confirmed",
              "summary": "?",
              "start": {"dateTime": "2026-05-16T09:00:00+02:00", "timeZone": "Europe/Berlin"},
              "end":   {"dateTime": "2026-05-16T09:30:00+02:00", "timeZone": "Europe/Berlin"},
              "eventType": "newGoogleType2027"
            }
            """
        let event = try decode(json)
        let payload = try XCTUnwrap(
            GoogleCalendarEventMapper.makeObservedPayload(
                event,
                calendar: calendarOwner,
                userDomain: "example.com"
            ))
        XCTAssertEqual(payload["event_type"] as? String, "other")
        assertNoForbiddenKeys(payload)
    }

    func testNilAttendeesMapsToZeroCounts() throws {
        let json = """
            {
              "id": "solo1",
              "status": "confirmed",
              "summary": "Solo block",
              "start": {"dateTime": "2026-05-16T09:00:00+02:00", "timeZone": "Europe/Berlin"},
              "end":   {"dateTime": "2026-05-16T10:00:00+02:00", "timeZone": "Europe/Berlin"},
              "eventType": "default"
            }
            """
        let event = try decode(json)
        let payload = try XCTUnwrap(
            GoogleCalendarEventMapper.makeObservedPayload(
                event,
                calendar: calendarOwner,
                userDomain: "example.com"
            ))
        XCTAssertEqual(payload["attendees_count"] as? Int, 0)
        XCTAssertEqual(payload["external_attendee_count"] as? Int, 0)
        XCTAssertNil(payload["self_response_status"])
        assertNoForbiddenKeys(payload)
    }

    func testTimezonePassthrough() throws {
        let json = """
            {
              "id": "tz1",
              "status": "confirmed",
              "summary": "Meeting",
              "start": {"dateTime": "2026-05-16T09:00:00+02:00", "timeZone": "Europe/Berlin"},
              "end":   {"dateTime": "2026-05-16T09:30:00+02:00", "timeZone": "Europe/Berlin"},
              "eventType": "default"
            }
            """
        let event = try decode(json)
        let payload = try XCTUnwrap(
            GoogleCalendarEventMapper.makeObservedPayload(
                event,
                calendar: calendarOwner,
                userDomain: "example.com"
            ))
        XCTAssertEqual(payload["timezone"] as? String, "Europe/Berlin")
        assertNoForbiddenKeys(payload)
    }
}
// swiftlint:enable force_unwrapping
