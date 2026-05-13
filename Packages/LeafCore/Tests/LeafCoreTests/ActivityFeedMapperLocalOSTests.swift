// Phase Track-4 S4 — ActivityFeedMapper LocalOS branch coverage.
//
// Track-4 S1+S2+S3 landed 36 new `event_kind` discriminators под different
// signal types (`.attention` / `.context` / `.action` / `.content`) без
// `payload["source"]` key — without an explicit whitelist they fall through
// to the generic mapAttention/mapIntegration paths and either drop or render
// without semantic copy. This test suite locks in:
//
// 1) Each of the 33 visible Track-4 kinds renders semantically.
// 2) Mapper reads ONLY allowlisted payload fields (ADR-010 redaction).
// 3) Unknown event_kinds still fall through unchanged.

import XCTest
@testable import LeafCore

final class ActivityFeedMapperLocalOSTests: XCTestCase {

    private func payloadJSON(_ dict: [String: String]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func map(
        kind: String,
        signalType: String = "context",
        bundleID: String? = nil,
        extras: [String: String] = [:]
    ) -> ActivityFeedEntry? {
        var payload = ["event_kind": kind]
        for (k, v) in extras { payload[k] = v }
        return ActivityFeedMapper.map(
            id: 1, timestampMs: 1_000, signalType: signalType,
            bundleID: bundleID, payloadJSON: payloadJSON(payload)
        )
    }

    // MARK: - S1 (Layer A architecture catch-up — 9 kinds)

    func testMeetingStateEntered() {
        let entry = map(kind: "meeting_state_entered")
        XCTAssertEqual(entry?.primaryText, "Meeting started")
        XCTAssertEqual(entry?.provider, .local)
    }

    func testMeetingStateExited() {
        XCTAssertEqual(map(kind: "meeting_state_exited")?.primaryText, "Meeting ended")
    }

    func testFocusModeEnabled() {
        let entry = map(kind: "focus_mode_enabled", extras: ["mode": "Work"])
        XCTAssertEqual(entry?.primaryText, "Focus on")
        XCTAssertEqual(entry?.secondaryText, "Work")
    }

    func testFocusModeDisabled() {
        XCTAssertEqual(map(kind: "focus_mode_disabled")?.primaryText, "Focus off")
    }

    func testSystemLocked() {
        XCTAssertEqual(map(kind: "system_locked")?.primaryText, "Screen locked")
    }

    func testSystemUnlocked() {
        XCTAssertEqual(map(kind: "system_unlocked")?.primaryText, "Screen unlocked")
    }

    func testSystemSlept() {
        XCTAssertEqual(map(kind: "system_slept")?.primaryText, "System sleep")
    }

    func testSystemWoke() {
        XCTAssertEqual(map(kind: "system_woke")?.primaryText, "System wake")
    }

    func testSpaceSwitched() {
        XCTAssertEqual(map(kind: "space_switched")?.primaryText, "Space switched")
    }

    // MARK: - S2 (AppleScript surface — 14 kinds)

    func testXcodeActiveDocChanged() {
        let entry = map(
            kind: "xcode_active_doc_changed", signalType: "attention",
            bundleID: "com.apple.dt.Xcode",
            extras: ["document_path": "/Users/me/Project/Foo.swift"]
        )
        XCTAssertEqual(entry?.primaryText, "Xcode: Foo.swift")
    }

    func testXcodeBuildStateChanged() {
        let entry = map(
            kind: "xcode_build_state_changed", signalType: "context",
            bundleID: "com.apple.dt.Xcode",
            extras: ["build_state": "succeeded"]
        )
        XCTAssertEqual(entry?.primaryText, "Xcode: build succeeded")
    }

    func testJetbrainsActiveDocChanged() {
        let entry = map(
            kind: "jetbrains_active_doc_changed", signalType: "attention",
            bundleID: "com.jetbrains.intellij",
            extras: ["document_path": "src/Main.kt"]
        )
        XCTAssertEqual(entry?.primaryText, "JetBrains: Main.kt")
    }

    func testMusicTrackChanged() {
        let entry = map(
            kind: "music_track_changed", signalType: "attention",
            bundleID: "com.apple.Music",
            extras: ["track_name": "Strawberry Fields", "artist": "Beatles"]
        )
        XCTAssertEqual(entry?.primaryText, "Music: Strawberry Fields")
        XCTAssertEqual(entry?.secondaryText, "Beatles")
    }

    func testSpotifyTrackChanged() {
        let entry = map(
            kind: "spotify_track_changed", signalType: "attention",
            bundleID: "com.spotify.client",
            extras: ["track_name": "Yesterday", "artist": "Beatles"]
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
        let entry = map(
            kind: "reminder_completed", signalType: "action",
            bundleID: "com.apple.reminders",
            extras: ["count": "3"]
        )
        XCTAssertEqual(entry?.primaryText, "Reminders completed: 3")
    }

    func testCalendarAppViewChanged() {
        let entry = map(
            kind: "calendar_app_view_changed", signalType: "attention",
            bundleID: "com.apple.iCal",
            extras: ["view": "week"]
        )
        XCTAssertEqual(entry?.primaryText, "Calendar: week view")
    }

    func testMailActiveMailboxChanged() {
        let entry = map(
            kind: "mail_active_mailbox_changed", signalType: "attention",
            bundleID: "com.apple.mail",
            extras: ["mailbox": "Inbox"]
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
        let entry = map(
            kind: "safari_tabs_changed", signalType: "attention",
            bundleID: "com.apple.Safari",
            extras: ["tab_count": "12"]
        )
        XCTAssertEqual(entry?.primaryText, "Safari: 12 tabs")
    }

    func testChromeTabsChanged() {
        let entry = map(
            kind: "chrome_tabs_changed", signalType: "attention",
            bundleID: "com.google.Chrome",
            extras: ["tab_count": "8"]
        )
        XCTAssertEqual(entry?.primaryText, "Chrome: 8 tabs")
    }

    func testArcTabsChanged() {
        let entry = map(
            kind: "arc_tabs_changed", signalType: "attention",
            bundleID: "company.thebrowser.Browser",
            extras: ["tab_count": "5"]
        )
        XCTAssertEqual(entry?.primaryText, "Arc: 5 tabs")
    }

    // MARK: - S3 (System observers — 10 visible of 13)

    func testAudioRouteChanged() {
        let entry = map(kind: "audio_route_changed", signalType: "context",
                        extras: ["category": "headphones"])
        XCTAssertEqual(entry?.primaryText, "Audio route: headphones")
    }

    func testMicInUseEntered() {
        XCTAssertEqual(map(kind: "mic_in_use_entered")?.primaryText, "Mic on")
    }

    func testMicInUseExited() {
        XCTAssertEqual(map(kind: "mic_in_use_exited")?.primaryText, "Mic off")
    }

    func testDisplayConnected() {
        let entry = map(kind: "display_connected", signalType: "context",
                        extras: ["display_count": "2"])
        XCTAssertEqual(entry?.primaryText, "Display connected")
        XCTAssertEqual(entry?.secondaryText, "2 displays")
    }

    func testDisplayDisconnected() {
        let entry = map(kind: "display_disconnected", signalType: "context",
                        extras: ["display_count": "1"])
        XCTAssertEqual(entry?.primaryText, "Display disconnected")
        XCTAssertEqual(entry?.secondaryText, "1 display")
    }

    func testVPNStateChanged() {
        let entry = map(kind: "vpn_state_changed", signalType: "context",
                        extras: ["state": "connected"])
        XCTAssertEqual(entry?.primaryText, "VPN: connected")
    }

    func testWifiStateChanged() {
        let entry = map(kind: "wifi_state_changed", signalType: "context",
                        extras: ["state": "associated"])
        XCTAssertEqual(entry?.primaryText, "Wi-Fi: associated")
    }

    func testScreenshotTaken() {
        let entry = map(kind: "screenshot_taken", signalType: "content",
                        extras: ["filename": "Screen Shot 2026-05-13.png"])
        XCTAssertEqual(entry?.primaryText, "Screenshot: Screen Shot 2026-05-13.png")
    }

    func testDownloadAdded() {
        let entry = map(kind: "download_added", signalType: "content",
                        extras: ["filename": "report.pdf"])
        XCTAssertEqual(entry?.primaryText, "Download: report.pdf")
    }

    func testTrashChangedEmptied() {
        let entry = map(kind: "trash_changed", signalType: "context",
                        extras: ["action": "emptied"])
        XCTAssertEqual(entry?.primaryText, "Trash emptied")
    }

    func testTrashChangedAdded() {
        let entry = map(kind: "trash_changed", signalType: "context",
                        extras: ["action": "added"])
        XCTAssertEqual(entry?.primaryText, "Trash items added")
    }

    // MARK: - Privacy walkbacks

    func testNoLeakageFromUnauthorizedPayloadFields() {
        // Mapper must NOT pick up any field not in its per-kind allowlist.
        let entry = map(
            kind: "notes_active_title_changed", signalType: "attention",
            bundleID: "com.apple.Notes",
            extras: [
                "note_title": "Q1 review",
                "note_body": "secret content",
                "preview": "secret preview"
            ]
        )
        XCTAssertEqual(entry?.primaryText, "Notes: Q1 review")
        XCTAssertNil(entry?.secondaryText)
        XCTAssertFalse((entry?.primaryText ?? "").contains("secret"))
        XCTAssertFalse((entry?.secondaryText ?? "").contains("secret"))
    }

    func testMissingExpectedPayloadFieldFallsBackGracefully() {
        // mic_in_use_entered carries no extras — primaryText is static, no crash.
        XCTAssertEqual(map(kind: "mic_in_use_entered")?.primaryText, "Mic on")
    }

    func testUnknownEventKindFallsThrough() {
        // event_kind not in whitelist → nil (no signalType-routed fallback).
        XCTAssertNil(map(kind: "totally_unknown_kind"))
    }

    // MARK: - Skip-list noise filter (high-cadence S3 substrate metrics)

    // Skip-list tests pass a populated bundleID so the skip is exercised via
    // `skippedKinds` membership rather than `mapAttention`'s bundleID guard.
    // Without this, removing the kind from `skippedKinds` would still produce
    // nil (incidental pass through guard) and silently lose the filter.

    func testIntensitySnapshotSkipped() {
        let entry = map(
            kind: "intensity_snapshot", signalType: "attention",
            bundleID: "com.apple.dt.Xcode",
            extras: ["keystroke_count": "30", "mouse_move_count": "60", "foreground_app": "com.apple.dt.Xcode"]
        )
        XCTAssertNil(entry, "intensity_snapshot must be filtered from feed (per-minute cadence)")
    }

    func testIntensityBucketDroppedSkipped() {
        let entry = map(
            kind: "intensity_bucket_dropped", signalType: "attention",
            bundleID: "com.apple.Finder",
            extras: ["state": "locked"]
        )
        XCTAssertNil(entry, "intensity_bucket_dropped must be filtered (AFK debug marker)")
    }

    func testClipboardEventCountSkipped() {
        let entry = map(
            kind: "clipboard_event_count", signalType: "context",
            bundleID: "com.apple.Safari",
            extras: ["count": "5"]
        )
        XCTAssertNil(entry, "clipboard_event_count must be filtered (per-tick counter)")
    }
}
