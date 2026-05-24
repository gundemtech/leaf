// Phase Track-6 P5 — Parity fence for the 3 new Zoom-deep ShareEventTypeKey
// entries. Locks down: (a) the enum cases exist with canonical raw values,
// (b) defaults are OFF per ADR-020, (c) the running registry total is 185
// post-P5 на integration-T10 (= 182 baseline post-P3 Browsers + 3 Track-6 P5).
// Track-10 base time the count was 155 (152+3); integration baseline is 182 because
// it already carries P1 Claude Code (+16) and P2 Xcode (+6) и P3 Browsers (+8).

import XCTest
@testable import LeafCore

final class ShareEventTypeRegistryP5Tests: XCTestCase {

    func testRegistrySize155AfterP5() {
        XCTAssertEqual(ShareEventTypeKey.allCases.count, 185,
                       "integration-T10 baseline 182 (post-P3 Browsers) + Track-6 P5 (started/ended/calendar_linked) = 185")
        XCTAssertEqual(ShareEventTypeDefaults.all.count, 185,
                       "defaults table must enumerate every ShareEventTypeKey case")
    }

    func testP5KindsHaveCanonicalRawValues() {
        XCTAssertEqual(ShareEventTypeKey.zoomMeetingStarted.rawValue, "zoom_meeting_started")
        XCTAssertEqual(ShareEventTypeKey.zoomMeetingEnded.rawValue, "zoom_meeting_ended")
        XCTAssertEqual(ShareEventTypeKey.zoomMeetingCalendarLinked.rawValue, "zoom_meeting_calendar_linked")
    }

    func testP5KindsAreDefaultOff() {
        let defaultsByKey = Dictionary(
            uniqueKeysWithValues: ShareEventTypeDefaults.all.map { ($0.key, $0.defaultEnabled) }
        )
        XCTAssertEqual(defaultsByKey[.zoomMeetingStarted], false)
        XCTAssertEqual(defaultsByKey[.zoomMeetingEnded], false)
        XCTAssertEqual(defaultsByKey[.zoomMeetingCalendarLinked], false)
    }

    func testS2BaselineKindsStillPresent() {
        // Regression: existing S2 Zoom kinds must not be removed by P5.
        let kinds = Set(ShareEventTypeKey.allCases.map { $0.rawValue })
        XCTAssertTrue(kinds.contains("zoom_meeting_state_changed"))
        XCTAssertTrue(kinds.contains("zoom_meeting_name_observed"))
    }
}
