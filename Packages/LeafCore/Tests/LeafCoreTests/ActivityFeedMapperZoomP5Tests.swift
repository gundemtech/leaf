// Phase Track-6 P5 — ActivityFeedMapper LocalOS coverage for 3 new Zoom kinds.
// Locks in:
//   1. mapLocalOS renders semantic primaryText/secondaryText per spec §11.1
//   2. ADR-010 redaction: NO meeting_topic/participant/url passed through
//   3. formatDurationCompact helper handles boundary cases

import XCTest

@testable import LeafCore

final class ActivityFeedMapperZoomP5Tests: XCTestCase {

    private func payloadJSON(_ dict: [String: String]) -> String {
        // swiftlint:disable:next force_try -- test fixture; [String: String] always JSON-serializable
        let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func map(
        kind: String,
        extras: [String: String] = [:]
    ) -> ActivityFeedEntry? {
        var payload: [String: String] = ["event_kind": kind]
        for (k, v) in extras { payload[k] = v }
        return ActivityFeedMapper.map(
            id: 1, timestampMs: 1_000, signalType: "context",
            bundleID: "us.zoom.xos", payloadJSON: payloadJSON(payload)
        )
    }

    // MARK: - zoom_meeting_started

    func testStartedColdRendersAlreadyInProgress() {
        let entry = map(kind: "zoom_meeting_started", extras: ["cold_start": "true", "started_at_ms": "1000"])
        XCTAssertEqual(entry?.primaryText, "Zoom meeting (already in progress)")
        XCTAssertNil(entry?.secondaryText)
        XCTAssertEqual(entry?.provider, .local)
    }

    func testStartedWarmRendersMeetingStarted() {
        let entry = map(kind: "zoom_meeting_started", extras: ["cold_start": "false"])
        XCTAssertEqual(entry?.primaryText, "Zoom meeting started")
        XCTAssertNil(entry?.secondaryText)
    }

    func testStartedDefaultsColdStartFalse() {
        // Missing cold_start field — defaults to "warm" copy.
        let entry = map(kind: "zoom_meeting_started")
        XCTAssertEqual(entry?.primaryText, "Zoom meeting started")
    }

    // MARK: - zoom_meeting_ended

    func testEndedShortSeconds() {
        let entry = map(kind: "zoom_meeting_ended", extras: ["duration_seconds": "45"])
        XCTAssertEqual(entry?.primaryText, "Zoom meeting ended")
        XCTAssertEqual(entry?.secondaryText, "Duration: 45s")
    }

    func testEndedMediumMinutes() {
        let entry = map(kind: "zoom_meeting_ended", extras: ["duration_seconds": "2700"])
        XCTAssertEqual(entry?.secondaryText, "Duration: 45m")
    }

    func testEndedLongHoursAndMinutes() {
        let entry = map(kind: "zoom_meeting_ended", extras: ["duration_seconds": "4980"])
        XCTAssertEqual(entry?.secondaryText, "Duration: 1h 23m")
    }

    func testEndedZeroDurationRendersZeroSeconds() {
        let entry = map(kind: "zoom_meeting_ended", extras: ["duration_seconds": "0"])
        XCTAssertEqual(entry?.secondaryText, "Duration: 0s")
    }

    func testEndedMissingDurationDefaultsZero() {
        let entry = map(kind: "zoom_meeting_ended")
        XCTAssertEqual(entry?.secondaryText, "Duration: 0s")
    }

    // MARK: - zoom_meeting_calendar_linked

    func testCalendarLinkedRendersCopy() {
        let entry = map(kind: "zoom_meeting_calendar_linked", extras: ["linked_calendar_event_id": "abc"])
        XCTAssertEqual(entry?.primaryText, "Zoom meeting linked to calendar")
        XCTAssertNil(entry?.secondaryText)
    }

    // MARK: - ADR-010 redaction guarantees

    func testStartedIgnoresForbiddenPayloadFields() {
        // Inject forbidden field — mapper must NOT include it in any field.
        let entry = map(
            kind: "zoom_meeting_started",
            extras: [
                "cold_start": "false",
                "meeting_topic": "SECRET-TOPIC-DO-NOT-LEAK",
                "attendees": "evil@example.com",
                "meeting_join_url": "https://zoom.us/j/9999",
            ])
        // primaryText must not contain any forbidden value.
        let primary = entry?.primaryText ?? ""
        XCTAssertFalse(primary.contains("SECRET-TOPIC-DO-NOT-LEAK"))
        XCTAssertFalse(primary.contains("evil@example.com"))
        XCTAssertFalse(primary.contains("zoom.us/j/9999"))
        XCTAssertNil(entry?.secondaryText)
    }

    func testEndedIgnoresForbiddenPayloadFields() {
        let entry = map(
            kind: "zoom_meeting_ended",
            extras: [
                "duration_seconds": "60",
                "meeting_topic": "SECRET-TOPIC",
                "participant_count": "10",
                "recording_state": "true",
            ])
        let combined = (entry?.primaryText ?? "") + (entry?.secondaryText ?? "")
        XCTAssertFalse(combined.contains("SECRET-TOPIC"))
        XCTAssertFalse(combined.contains("10"))
        XCTAssertFalse(combined.contains("recording"))
    }

    // MARK: - formatDurationCompact helper boundary cases

    func testFormatDurationCompactBoundaries() {
        XCTAssertEqual(ActivityFeedMapper.formatDurationCompact(0), "0s")
        XCTAssertEqual(ActivityFeedMapper.formatDurationCompact(59), "59s")
        XCTAssertEqual(ActivityFeedMapper.formatDurationCompact(60), "1m")
        XCTAssertEqual(ActivityFeedMapper.formatDurationCompact(3599), "59m")
        XCTAssertEqual(ActivityFeedMapper.formatDurationCompact(3600), "1h")
        XCTAssertEqual(ActivityFeedMapper.formatDurationCompact(3660), "1h 1m")
        XCTAssertEqual(ActivityFeedMapper.formatDurationCompact(7320), "2h 2m")
        XCTAssertEqual(
            ActivityFeedMapper.formatDurationCompact(-100), "0s",
            "Negative seconds should clamp to 0")
    }
}
