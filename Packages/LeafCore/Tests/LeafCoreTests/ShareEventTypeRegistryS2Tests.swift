import XCTest
@testable import LeafCore

final class ShareEventTypeRegistryS2Tests: XCTestCase {
    // Track 4 S2 grew it 125 → 139. Track 4 S3 grew it 139 → 152.
    // Track-6 P1 grew it 152 → 168. Track-6 P2 grew it 168 → 174. Track-6 P3 grew it 174 → 182 (+8 Browsers Deep).
    // Track-6 P5 grew it 182 → 185 (+3 Zoom Deep).
    func testRegistrySizeIs139() {
        XCTAssertEqual(ShareEventTypeKey.allCases.count, 185)
    }

    func testDefaultsCountMatches() {
        XCTAssertEqual(ShareEventTypeDefaults.all.count, 185)
    }

    func testAllNewS2KeysDefaultOff() {
        let newKeys: Set<ShareEventTypeKey> = [
            .xcodeActiveDocChanged, .xcodeBuildStateChanged,
            .jetbrainsActiveDocChanged,
            .musicTrackChanged, .spotifyTrackChanged,
            .notesActiveTitleChanged,
            .reminderCompleted,
            .calendarAppViewChanged,
            .mailActiveMailboxChanged,
            .zoomMeetingStateChanged, .zoomMeetingNameObserved,
            .safariTabsChanged, .chromeTabsChanged, .arcTabsChanged
        ]
        let defaultsByKey = Dictionary(uniqueKeysWithValues: ShareEventTypeDefaults.all.map { ($0.key, $0.defaultEnabled) })
        for k in newKeys {
            XCTAssertEqual(defaultsByKey[k], false, "expected \(k) default OFF")
        }
    }

    func testRawValuesUseSnakeCase() {
        XCTAssertEqual(ShareEventTypeKey.xcodeActiveDocChanged.rawValue, "xcode_active_doc_changed")
        XCTAssertEqual(ShareEventTypeKey.mailActiveMailboxChanged.rawValue, "mail_active_mailbox_changed")
        XCTAssertEqual(ShareEventTypeKey.safariTabsChanged.rawValue, "safari_tabs_changed")
        XCTAssertEqual(ShareEventTypeKey.zoomMeetingNameObserved.rawValue, "zoom_meeting_name_observed")
    }
}
