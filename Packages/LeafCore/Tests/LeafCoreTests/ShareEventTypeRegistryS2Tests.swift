import XCTest
@testable import LeafCore

final class ShareEventTypeRegistryS2Tests: XCTestCase {
    func testRegistrySizeIs139() {
        XCTAssertEqual(ShareEventTypeKey.allCases.count, 155)
    }

    func testDefaultsCountMatches() {
        XCTAssertEqual(ShareEventTypeDefaults.all.count, 155)
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
