// Phase Track-6 P5 — Parity fence for the 3 new Zoom-deep ShareEventTypeKey
// entries. Locks down: (a) the enum cases exist with canonical raw values,
// (b) defaults are OFF per ADR-020, (c) the running registry total is 155
// post-P5 (= 152 baseline + 3 Track-6 P5).

import XCTest
@testable import LeafCore

final class ShareEventTypeRegistryP5Tests: XCTestCase {

    func testRegistrySize155AfterP5() {
        // Track-6 integration combined: 152 baseline + 16 P1 + 8 P3 + 6 P4 + 6 P2 + 3 P5 = 191.
        XCTAssertEqual(ShareEventTypeKey.allCases.count, 191,
                       "Track-6 P1+P3+P4+P2+P5 collective merge = 191")
        XCTAssertEqual(ShareEventTypeDefaults.all.count, 191,
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
