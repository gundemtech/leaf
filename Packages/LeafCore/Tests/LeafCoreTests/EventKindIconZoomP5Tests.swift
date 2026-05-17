// Phase Track-6 P5 — EventKindIcon SF Symbol mappings for new Zoom kinds.
// Visual distinction:
//   - baseline S2 kinds use `video.circle` (transition events)
//   - P5 started/ended/calendar_linked use distinct icons for aggregated session view

import XCTest

@testable import LeafCore

final class EventKindIconZoomP5Tests: XCTestCase {

    func testZoomMeetingStartedIcon() {
        XCTAssertEqual(EventKindIcon.symbol(for: "zoom_meeting_started"), "video.fill")
    }

    func testZoomMeetingEndedIcon() {
        XCTAssertEqual(EventKindIcon.symbol(for: "zoom_meeting_ended"), "video.slash")
    }

    func testZoomMeetingCalendarLinkedIcon() {
        XCTAssertEqual(EventKindIcon.symbol(for: "zoom_meeting_calendar_linked"), "link.circle")
    }

    func testNewKindsDistinctFromBaseline() {
        // Baseline kinds keep `video.circle`; P5 kinds must NOT collapse to same symbol.
        let baseline = EventKindIcon.symbol(for: "zoom_meeting_state_changed")
        let p5Started = EventKindIcon.symbol(for: "zoom_meeting_started")
        let p5Ended = EventKindIcon.symbol(for: "zoom_meeting_ended")
        let p5Linked = EventKindIcon.symbol(for: "zoom_meeting_calendar_linked")
        XCTAssertEqual(baseline, "video.circle")
        XCTAssertNotEqual(p5Started, baseline)
        XCTAssertNotEqual(p5Ended, baseline)
        XCTAssertNotEqual(p5Linked, baseline)
    }
}
