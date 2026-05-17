// Phase Track-4 S2 — AppleScript surface (14 kinds) for ActivityFeedMapper.
// Split from ActivityFeedMapperLocalOSTests.swift for type_body_length / file_length.

import XCTest

@testable import LeafCore

final class ActivityFeedMapperLocalOSAppleScriptTests: XCTestCase {
    private typealias Support = ActivityFeedMapperLocalOSTestSupport

    private func map(
        kind: String,
        signalType: String = "context",
        bundleID: String? = nil,
        extras: [String: String] = [:]
    ) -> ActivityFeedEntry? {
        Support.map(kind: kind, signalType: signalType, bundleID: bundleID, extras: extras)
    }

    func testXcodeActiveDocChanged() {
        // XcodeStateMachine emits `doc_path` (Schema.EventPayloadKeys.docPath).
        let entry = map(
            kind: "xcode_active_doc_changed", signalType: "attention",
            bundleID: "com.apple.dt.Xcode",
            extras: ["doc_path": "/Users/me/Project/Foo.swift"]
        )
        XCTAssertEqual(entry?.primaryText, "Xcode: Foo.swift")
    }

    func testXcodeBuildStateChanged() {
        let entry = map(
            kind: "xcode_build_state_changed", signalType: "attention",
            bundleID: "com.apple.dt.Xcode",
            extras: ["build_state": "succeeded"]
        )
        XCTAssertEqual(entry?.primaryText, "Xcode: build succeeded")
    }

    func testJetbrainsActiveDocChanged() {
        // JetBrainsStateMachine emits `doc_path` matching Xcode.
        let entry = map(
            kind: "jetbrains_active_doc_changed", signalType: "attention",
            bundleID: "com.jetbrains.intellij",
            extras: ["doc_path": "src/Main.kt"]
        )
        XCTAssertEqual(entry?.primaryText, "JetBrains: Main.kt")
    }

    func testMusicTrackChanged() {
        // MusicStateMachine emits `track` (not `track_name`) + `artist`.
        let entry = map(
            kind: "music_track_changed", signalType: "attention",
            bundleID: "com.apple.Music",
            extras: ["track": "Strawberry Fields", "artist": "Beatles"]
        )
        XCTAssertEqual(entry?.primaryText, "Music: Strawberry Fields")
        XCTAssertEqual(entry?.secondaryText, "Beatles")
    }

    func testSpotifyTrackChanged() {
        let entry = map(
            kind: "spotify_track_changed", signalType: "attention",
            bundleID: "com.spotify.client",
            extras: ["track": "Yesterday", "artist": "Beatles"]
        )
        XCTAssertEqual(entry?.primaryText, "Spotify: Yesterday")
        XCTAssertEqual(entry?.secondaryText, "Beatles")
    }

    func testNotesActiveTitleChanged() {
        let entry = map(
            kind: "notes_active_title_changed", signalType: "attention",
            bundleID: "com.apple.Notes",
            extras: ["note_title": "Q1 review"]
        )
        XCTAssertEqual(entry?.primaryText, "Notes: Q1 review")
    }

    func testReminderCompleted() {
        // RemindersStateMachine emits `completed_count_delta` (positive int).
        let entry = map(
            kind: "reminder_completed", signalType: "attention",
            bundleID: "com.apple.reminders",
            extras: ["completed_count_delta": "3"]
        )
        XCTAssertEqual(entry?.primaryText, "Reminders completed: 3")
    }

    func testCalendarAppViewChanged() {
        // CalendarAppStateMachine emits `view_mode` (not `view`).
        let entry = map(
            kind: "calendar_app_view_changed", signalType: "attention",
            bundleID: "com.apple.iCal",
            extras: ["view_mode": "week"]
        )
        XCTAssertEqual(entry?.primaryText, "Calendar: week view")
    }

    func testMailActiveMailboxChanged() {
        // MailStateMachine emits `mailbox_name` (Schema.EventPayloadKeys.mailboxName).
        let entry = map(
            kind: "mail_active_mailbox_changed", signalType: "attention",
            bundleID: "com.apple.mail",
            extras: ["mailbox_name": "Inbox"]
        )
        XCTAssertEqual(entry?.primaryText, "Mail: Inbox")
    }

    func testZoomMeetingStateChanged() {
        let entry = map(
            kind: "zoom_meeting_state_changed", signalType: "context",
            bundleID: "us.zoom.xos",
            extras: ["meeting_state": "in_meeting"]
        )
        XCTAssertEqual(entry?.primaryText, "Zoom: in meeting")
    }

    func testZoomMeetingNameObserved() {
        let entry = map(
            kind: "zoom_meeting_name_observed", signalType: "context",
            bundleID: "us.zoom.xos",
            extras: ["meeting_topic": "Sprint planning"]
        )
        XCTAssertEqual(entry?.primaryText, "Zoom: Sprint planning")
    }

    func testSafariTabsChanged() {
        // Safari/Chrome/ArcStateMachine emit `tabs` as JSON array of BrowserTab.
        // Mapper counts array length structurally — never reads url/title.
        let tabsJSON =
            #"[{"url":"https://a","title":"A"},{"url":"https://b","title":"B"},{"url":"https://c","title":"C"}]"#
        let entry = map(
            kind: "safari_tabs_changed", signalType: "attention",
            bundleID: "com.apple.Safari",
            extras: ["tabs": tabsJSON]
        )
        XCTAssertEqual(entry?.primaryText, "Safari: 3 tabs")
    }

    func testChromeTabsChanged() {
        let tabsJSON = #"[{"url":"https://a","title":"A"},{"url":"https://b","title":"B"}]"#
        let entry = map(
            kind: "chrome_tabs_changed", signalType: "attention",
            bundleID: "com.google.Chrome",
            extras: ["tabs": tabsJSON]
        )
        XCTAssertEqual(entry?.primaryText, "Chrome: 2 tabs")
    }

    func testArcTabsChanged() {
        let tabsJSON = #"[{"url":"https://a","title":"A"}]"#
        let entry = map(
            kind: "arc_tabs_changed", signalType: "attention",
            bundleID: "company.thebrowser.Browser",
            extras: ["tabs": tabsJSON]
        )
        XCTAssertEqual(entry?.primaryText, "Arc: 1 tabs")
    }

    func testBrowserTabsCountUnparseableFallsBackGracefully() {
        // If `tabs` is missing / malformed, mapper renders "?" rather than
        // crashing or showing "0".
        let entry = map(
            kind: "safari_tabs_changed", signalType: "attention",
            bundleID: "com.apple.Safari",
            extras: ["tabs": "not-json"]
        )
        XCTAssertEqual(entry?.primaryText, "Safari: ? tabs")
    }
}
