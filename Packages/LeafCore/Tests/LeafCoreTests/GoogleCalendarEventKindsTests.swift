import XCTest

@testable import LeafCore

final class GoogleCalendarEventKindsTests: XCTestCase {
    func testAllCasesCountIsSix() {
        XCTAssertEqual(GoogleCalendarEventKind.allCases.count, 6)
    }

    func testRawValuesMatchSpec() {
        let expected: [GoogleCalendarEventKind: String] = [
            .eventObserved: "google_calendar_event_observed",
            .focusBlockStarted: "google_calendar_focus_block_started",
            .focusBlockEnded: "google_calendar_focus_block_ended",
            .oooStarted: "google_calendar_ooo_started",
            .oooEnded: "google_calendar_ooo_ended",
            .workingLocationChanged: "google_calendar_working_location_changed",
        ]
        for (kind, raw) in expected {
            XCTAssertEqual(kind.rawValue, raw, "\(kind) rawValue mismatch")
        }
    }

    func testShareEventTypeRegistryHasSixGoogleCalendarKeys() {
        let googleKeys = ShareEventTypeKey.allCases.filter { $0.rawValue.hasPrefix("google_calendar_") }
        XCTAssertEqual(googleKeys.count, 6)
    }

    func testPresenceStateProviderEnumHasGoogleCalendar() {
        XCTAssertEqual(PresenceStateWriter.Provider.googleCalendar.rawValue, "google_calendar")
    }
}
