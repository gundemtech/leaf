import XCTest
@testable import LeafCore

final class GoogleCalendarEventKindsTests: XCTestCase {
    func test_allCases_count_is_six() {
        XCTAssertEqual(GoogleCalendarEventKind.allCases.count, 6)
    }

    func test_rawValues_match_spec() {
        let expected: [GoogleCalendarEventKind: String] = [
            .eventObserved:              "google_calendar_event_observed",
            .focusBlockStarted:          "google_calendar_focus_block_started",
            .focusBlockEnded:            "google_calendar_focus_block_ended",
            .oooStarted:                 "google_calendar_ooo_started",
            .oooEnded:                   "google_calendar_ooo_ended",
            .workingLocationChanged:     "google_calendar_working_location_changed",
        ]
        for (kind, raw) in expected {
            XCTAssertEqual(kind.rawValue, raw)
        }
    }

    func test_share_event_type_registry_has_six_google_calendar_keys() {
        let googleKeys = ShareEventTypeKey.allCases.filter { $0.rawValue.hasPrefix("google_calendar_") }
        XCTAssertEqual(googleKeys.count, 6)
    }

    func test_presence_state_provider_enum_has_googleCalendar() {
        XCTAssertEqual(PresenceStateWriter.Provider.googleCalendar.rawValue, "google_calendar")
    }
}
