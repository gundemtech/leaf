import XCTest

@testable import LeafCore

/// Track-6 P4 Task 3 — Codable decoding tests for Google Calendar API v3 shapes.
///
/// Coverage:
/// 1. EventsListResponse with `nextSyncToken` (incremental sync cursor).
/// 2. Default event with attendees + recurrence + organizer + conferenceData.
/// 3. focusTime event — `focusTimeProperties` (autoDeclineMode, declineMessage decoded
///    but Mapper drops per ADR-010, chatStatus).
/// 4. Cancelled instance — limited fields only (`status="cancelled"`, `recurringEventId`,
///    `originalStartTime`).
/// 5. CalendarListResponse with mix of owner/writer/reader and `primary=true`.
/// 6. OAuth TokenResponse — snake_case → camelCase mapping.
/// 7. 410 ErrorEnvelope with `fullSyncRequired` reason (sync token expired).
final class GoogleCalendarAPIDecodingTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testDecodeEventsListResponseWithSyncToken() throws {
        let json = """
            {
              "kind": "calendar#events",
              "etag": "\\"abc\\"",
              "summary": "primary",
              "updated": "2026-05-16T10:00:00.000Z",
              "timeZone": "Europe/Berlin",
              "accessRole": "owner",
              "items": [],
              "nextSyncToken": "TOKEN-XYZ"
            }
            """.data(using: .utf8)!
        let resp = try decoder.decode(GoogleCalendarAPI.EventsListResponse.self, from: json)
        XCTAssertEqual(resp.nextSyncToken, "TOKEN-XYZ")
        XCTAssertNil(resp.nextPageToken)
        XCTAssertEqual(resp.items.count, 0)
    }

    func testDecodeDefaultEventWithAttendeesAndRecurrence() throws {
        let json = """
            {
              "id": "evt1",
              "iCalUID": "evt1@google.com",
              "status": "confirmed",
              "summary": "Standup",
              "start":  {"dateTime": "2026-05-16T09:00:00+02:00", "timeZone": "Europe/Berlin"},
              "end":    {"dateTime": "2026-05-16T09:30:00+02:00", "timeZone": "Europe/Berlin"},
              "recurrence": ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"],
              "attendees": [
                {"email":"me@example.com","self":true,"responseStatus":"accepted"},
                {"email":"ext@other.com","responseStatus":"needsAction"}
              ],
              "organizer": {"email":"me@example.com","self":true},
              "eventType": "default",
              "transparency": "opaque",
              "visibility": "default",
              "created": "2026-05-01T00:00:00.000Z",
              "updated": "2026-05-15T00:00:00.000Z",
              "conferenceData": {
                "entryPoints": [{"entryPointType":"video","uri":"https://meet.example/abc"}],
                "conferenceSolution":{"key":{"type":"hangoutsMeet"}}
              }
            }
            """.data(using: .utf8)!
        let event = try decoder.decode(GoogleCalendarAPI.Event.self, from: json)
        XCTAssertEqual(event.id, "evt1")
        XCTAssertEqual(event.iCalUID, "evt1@google.com")
        XCTAssertEqual(event.status, "confirmed")
        XCTAssertEqual(event.summary, "Standup")
        XCTAssertEqual(event.eventType, "default")
        XCTAssertEqual(event.attendees?.count, 2)
        XCTAssertTrue(event.attendees!.contains { $0.isSelf == true && $0.responseStatus == "accepted" })
        XCTAssertEqual(event.organizer?.isSelf, true)
        XCTAssertEqual(event.recurrence, ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"])
        XCTAssertEqual(event.conferenceData?.entryPoints?.first?.entryPointType, "video")
        XCTAssertEqual(event.conferenceData?.conferenceSolution?.key?.type, "hangoutsMeet")
    }

    func testDecodeFocusTimeEventWithProperties() throws {
        let json = """
            {
              "id":"f1","iCalUID":"f1@google.com","status":"confirmed",
              "summary":"Deep work",
              "start":{"dateTime":"2026-05-16T14:00:00Z"},"end":{"dateTime":"2026-05-16T17:00:00Z"},
              "eventType":"focusTime",
              "focusTimeProperties":{
                "autoDeclineMode":"declineOnlyNewConflictingInvitations",
                "declineMessage":"Focusing — back later",
                "chatStatus":"doNotDisturb"
              }
            }
            """.data(using: .utf8)!
        let event = try decoder.decode(GoogleCalendarAPI.Event.self, from: json)
        XCTAssertEqual(event.eventType, "focusTime")
        XCTAssertEqual(event.focusTimeProperties?.autoDeclineMode, "declineOnlyNewConflictingInvitations")
        XCTAssertEqual(event.focusTimeProperties?.chatStatus, "doNotDisturb")
        // declineMessage decoded BUT mapper drops it (ADR-010) — see Task 6 walkback.
        XCTAssertEqual(event.focusTimeProperties?.declineMessage, "Focusing — back later")
    }

    func testDecodeCancelledInstanceWithLimitedFields() throws {
        let json = """
            {
              "id":"cancel1",
              "status":"cancelled",
              "recurringEventId":"parent1",
              "originalStartTime":{"dateTime":"2026-05-16T09:00:00Z"}
            }
            """.data(using: .utf8)!
        let event = try decoder.decode(GoogleCalendarAPI.Event.self, from: json)
        XCTAssertEqual(event.status, "cancelled")
        XCTAssertEqual(event.recurringEventId, "parent1")
        XCTAssertNil(event.summary)
        XCTAssertNil(event.attendees)
    }

    func testDecodeCalendarListResponse() throws {
        let json = """
            {
              "items":[
                {"id":"primary","summary":"Me","primary":true,"accessRole":"owner"},
                {"id":"abc@group.calendar.google.com","summary":"Engineering","accessRole":"writer"},
                {"id":"holidays@google.com","summary":"Holidays","accessRole":"reader"}
              ],
              "nextSyncToken":"CALSYNC"
            }
            """.data(using: .utf8)!
        let resp = try decoder.decode(GoogleCalendarAPI.CalendarListResponse.self, from: json)
        XCTAssertEqual(resp.items.count, 3)
        XCTAssertTrue(resp.items.first { $0.primary == true }?.accessRole == "owner")
        XCTAssertEqual(resp.nextSyncToken, "CALSYNC")
    }

    func testDecodeTokenResponse() throws {
        let json = """
            {"access_token":"ya29.abc","expires_in":3920,"refresh_token":"1//rt","scope":"https://www.googleapis.com/auth/calendar.readonly","token_type":"Bearer"}
            """.data(using: .utf8)!
        let resp = try decoder.decode(GoogleCalendarAPI.TokenResponse.self, from: json)
        XCTAssertEqual(resp.accessToken, "ya29.abc")
        XCTAssertEqual(resp.expiresIn, 3920)
        XCTAssertEqual(resp.refreshToken, "1//rt")
    }

    func testDecode410ErrorResponse() throws {
        let json = """
            {"error":{"code":410,"message":"Sync token is no longer valid","errors":[{"reason":"fullSyncRequired"}]}}
            """.data(using: .utf8)!
        let err = try decoder.decode(GoogleCalendarAPI.ErrorEnvelope.self, from: json)
        XCTAssertEqual(err.error.code, 410)
        XCTAssertEqual(err.error.errors?.first?.reason, "fullSyncRequired")
    }
}
