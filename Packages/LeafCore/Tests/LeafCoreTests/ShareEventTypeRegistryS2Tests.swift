import XCTest

@testable import LeafCore

final class ShareEventTypeRegistryS2Tests: XCTestCase {
    // Track 4 S2 grew it 125 → 139. Track 4 S3 grew it 139 → 152.
    // P1 168 → P3 176 → P4 182 → P2 188 → P5 191.
    func testRegistrySizeIs139() {
        XCTAssertEqual(ShareEventTypeKey.allCases.count, 195)
    }

    func testDefaultsCountMatches() {
        XCTAssertEqual(ShareEventTypeDefaults.all.count, 195)
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
            .safariTabsChanged, .chromeTabsChanged, .arcTabsChanged,
        ]
        let defaultsByKey = Dictionary(
            uniqueKeysWithValues: ShareEventTypeDefaults.all.map { ($0.key, $0.defaultEnabled) })
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
