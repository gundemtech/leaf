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
        // swiftlint:disable:next force_try -- test fixture; [String: String] always JSON-serializable
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
        // FocusModeCollector emits only `state` (focused / not_focused) — no
        // user-facing mode name is exposed by INFocusStatusCenter.isFocused, so
        // secondary line stays nil.
        let entry = map(kind: "focus_mode_enabled", extras: ["state": "focused"])
        XCTAssertEqual(entry?.primaryText, "Focus on")
        XCTAssertNil(entry?.secondaryText)
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

    // MARK: - S3 (System observers — 10 visible of 13)

    func testAudioRouteChanged() {
        // AudioRouteCollector emits `audio_route` (Schema.EventPayloadKeys.audioRoute)
        // carrying AudioRouteCategory enum rawValue (transport type only,
        // never device name — ADR-010).
        let entry = map(
            kind: "audio_route_changed", signalType: "context",
            extras: ["audio_route": "headphones"])
        XCTAssertEqual(entry?.primaryText, "Audio route: headphones")
    }

    func testMicInUseEntered() {
        XCTAssertEqual(map(kind: "mic_in_use_entered")?.primaryText, "Mic on")
    }

    func testMicInUseExited() {
        XCTAssertEqual(map(kind: "mic_in_use_exited")?.primaryText, "Mic off")
    }

    func testDisplayConnected() {
        // DisplayCollector emits payload {event_kind, state} — no count field
        // (`display_count` was never wired). Mapper renders primary only.
        let entry = map(
            kind: "display_connected", signalType: "context",
            extras: ["state": "display_connected"])
        XCTAssertEqual(entry?.primaryText, "Display connected")
        XCTAssertNil(entry?.secondaryText)
    }

    func testDisplayDisconnected() {
        let entry = map(
            kind: "display_disconnected", signalType: "context",
            extras: ["state": "display_disconnected"])
        XCTAssertEqual(entry?.primaryText, "Display disconnected")
        XCTAssertNil(entry?.secondaryText)
    }

    func testVPNStateChanged() {
        let entry = map(
            kind: "vpn_state_changed", signalType: "context",
            extras: ["state": "connected"])
        XCTAssertEqual(entry?.primaryText, "VPN: connected")
    }

    func testWifiStateChanged() {
        let entry = map(
            kind: "wifi_state_changed", signalType: "context",
            extras: ["state": "associated"])
        XCTAssertEqual(entry?.primaryText, "Wi-Fi: associated")
    }

    func testScreenshotTaken() {
        let entry = map(
            kind: "screenshot_taken", signalType: "content",
            extras: ["filename": "Screen Shot 2026-05-13.png"])
        XCTAssertEqual(entry?.primaryText, "Screenshot: Screen Shot 2026-05-13.png")
    }

    func testDownloadAdded() {
        let entry = map(
            kind: "download_added", signalType: "content",
            extras: ["filename": "report.pdf"])
        XCTAssertEqual(entry?.primaryText, "Download: report.pdf")
    }

    func testTrashChangedEmptied() {
        let entry = map(
            kind: "trash_changed", signalType: "context",
            extras: ["action": "emptied"])
        XCTAssertEqual(entry?.primaryText, "Trash emptied")
    }

    func testTrashChangedAdded() {
        let entry = map(
            kind: "trash_changed", signalType: "context",
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
                "preview": "secret preview",
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

    // MARK: - P3 Browser deep (8 new kinds)

    func testSafariTabNavigated() {
        let entry = map(
            kind: "safari_tab_navigated", signalType: "attention",
            bundleID: "com.apple.Safari",
            extras: ["current_url": "github.com/foo"]
        )
        XCTAssertEqual(entry?.primaryText, "Safari: github.com/foo")
        XCTAssertEqual(entry?.secondaryText, "navigated")
    }

    func testChromeTabNavigated() {
        let entry = map(
            kind: "chrome_tab_navigated", signalType: "attention",
            bundleID: "com.google.Chrome",
            extras: ["current_url": "linear.app"]
        )
        XCTAssertEqual(entry?.primaryText, "Chrome: linear.app")
        XCTAssertEqual(entry?.secondaryText, "navigated")
    }

    func testArcTabNavigated() {
        let entry = map(
            kind: "arc_tab_navigated", signalType: "attention",
            bundleID: "company.thebrowser.Browser",
            extras: ["current_url": "arc.net/explore"]
        )
        XCTAssertEqual(entry?.primaryText, "Arc: arc.net/explore")
        XCTAssertEqual(entry?.secondaryText, "navigated")
    }

    func testSafariTabActivated() {
        let entry = map(
            kind: "safari_tab_activated", signalType: "attention",
            bundleID: "com.apple.Safari",
            extras: ["current_url": "apple.com/developer"]
        )
        XCTAssertEqual(entry?.primaryText, "Safari: apple.com/developer")
        XCTAssertEqual(entry?.secondaryText, "tab activated")
    }

    func testChromeTabActivated() {
        let entry = map(
            kind: "chrome_tab_activated", signalType: "attention",
            bundleID: "com.google.Chrome",
            extras: ["current_url": "github.com/gundemtech"]
        )
        XCTAssertEqual(entry?.primaryText, "Chrome: github.com/gundemtech")
        XCTAssertEqual(entry?.secondaryText, "tab activated")
    }

    func testArcTabActivated() {
        let entry = map(
            kind: "arc_tab_activated", signalType: "attention",
            bundleID: "company.thebrowser.Browser",
            extras: ["current_url": "notion.so"]
        )
        XCTAssertEqual(entry?.primaryText, "Arc: notion.so")
        XCTAssertEqual(entry?.secondaryText, "tab activated")
    }

    func testChromeBookmarkChangedPositiveDelta() {
        // BookmarkCollector emits "delta" (signed int) + "total_count" (int) only —
        // no URL/title strings (ADR-010 structural count only).
        let entry = map(
            kind: "chrome_bookmark_changed", signalType: "action",
            bundleID: "com.google.Chrome",
            extras: ["delta": "1", "total_count": "143"]
        )
        XCTAssertEqual(entry?.primaryText, "Chrome bookmarks: +1 (143 total)")
        XCTAssertNil(entry?.secondaryText)
    }

    func testSafariBookmarkChangedNegativeDelta() {
        let entry = map(
            kind: "safari_bookmark_changed", signalType: "action",
            bundleID: "com.apple.Safari",
            extras: ["delta": "-1", "total_count": "11"]
        )
        XCTAssertEqual(entry?.primaryText, "Safari bookmarks: -1 (11 total)")
        XCTAssertNil(entry?.secondaryText)
    }

    // MARK: - Phase Track-6 P2 (Xcode Deep — 6 kinds)

    func testXcodeBuildStarted() {
        let entry = map(
            kind: "xcode_build_started", signalType: "attention",
            bundleID: "com.apple.dt.Xcode",
            extras: ["scheme": "Leaf", "run_destination_bucket": "macos"]
        )
        XCTAssertEqual(entry?.primaryText, "Xcode: build started")
        XCTAssertNotNil(entry?.secondaryText)
        XCTAssertTrue(entry?.secondaryText?.contains("Leaf") == true)
    }

    func testXcodeBuildFinishedSucceeded() {
        let entry = map(
            kind: "xcode_build_finished", signalType: "attention",
            bundleID: "com.apple.dt.Xcode",
            extras: [
                "status": "succeeded", "scheme": "Leaf",
                "run_destination_bucket": "macos",
            ]
        )
        XCTAssertEqual(entry?.primaryText, "Xcode: build succeeded")
    }

    func testXcodeBuildFinishedWithErrors() {
        let entry = map(
            kind: "xcode_build_finished", signalType: "attention",
            bundleID: "com.apple.dt.Xcode",
            extras: [
                "status": "failed", "scheme": "Leaf",
                "error_count": "4", "run_destination_bucket": "macos",
            ]
        )
        XCTAssertEqual(entry?.primaryText, "Xcode: build failed")
        XCTAssertTrue(entry?.secondaryText?.contains("4 errors") == true)
    }

    func testXcodeTestRunStarted() {
        let entry = map(
            kind: "xcode_test_run_started", signalType: "attention",
            bundleID: "com.apple.dt.Xcode",
            extras: ["scheme": "Leaf", "run_destination_bucket": "macos"]
        )
        XCTAssertEqual(entry?.primaryText, "Xcode: tests started")
        XCTAssertEqual(entry?.secondaryText, "Leaf")
    }

    func testXcodeTestRunFinished() {
        let entry = map(
            kind: "xcode_test_run_finished", signalType: "attention",
            bundleID: "com.apple.dt.Xcode",
            extras: [
                "status": "failed", "passed_count": "1500",
                "failed_count": "2", "total_count": "1502",
                "run_destination_bucket": "ios_simulator",
            ]
        )
        XCTAssertEqual(entry?.primaryText, "Xcode: tests failed")
        XCTAssertEqual(entry?.secondaryText, "1500 passed, 2 failed")
    }

    func testXcodeSchemeChanged() {
        let entry = map(
            kind: "xcode_scheme_changed", signalType: "attention",
            bundleID: "com.apple.dt.Xcode",
            extras: [
                "scheme": "LeafAgent", "scheme_prev": "Leaf",
                "project": "Leaf",
            ]
        )
        XCTAssertEqual(entry?.primaryText, "Xcode: scheme LeafAgent")
        XCTAssertEqual(entry?.secondaryText, "Leaf")
    }

    func testXcodeRunDestinationChanged() {
        let entry = map(
            kind: "xcode_run_destination_changed", signalType: "attention",
            bundleID: "com.apple.dt.Xcode",
            extras: [
                "run_destination_bucket": "ios_simulator",
                "run_destination_bucket_prev": "macos",
            ]
        )
        XCTAssertEqual(entry?.primaryText, "Xcode: target ios_simulator")
    }

    // ADR-010 walkback fence: synthetic sentinel injected into forbidden
    // payload positions must NOT appear in entry text (mapper reads only
    // allowlisted fields). Sentinel keys cover the full forbidden-field
    // surface from spec §8.1 — adding a key here forces a future maintainer
    // who accidentally reads `payload["device_name"]` etc. to confront the
    // walkback fence at test time, not at smoke-gate time.
    func testXcodeP2_WalkbackSentinel() {
        let sentinel = "LEAKED_SENTINEL_XCODE_P2"
        let kinds = [
            "xcode_build_started", "xcode_build_finished",
            "xcode_test_run_started", "xcode_test_run_finished",
            "xcode_scheme_changed", "xcode_run_destination_changed",
        ]
        let forbiddenKeys: [String] = [
            "raw_device_name", "device_name", "deviceName",
            "error_message", "errors", "compiler_error",
            "source_url", "sourceURL", "file_url",
            "test_identifier", "test_name", "test_method_name",
            "failure_message", "failureMessage",
            "model_name", "modelName", "os_build_number",
            "build_log", "activity_log", "stderr", "stdout",
        ]
        var sentinelPayload: [String: String] = [:]
        for k in forbiddenKeys { sentinelPayload[k] = sentinel }
        for kind in kinds {
            let entry = map(
                kind: kind, signalType: "attention",
                bundleID: "com.apple.dt.Xcode",
                extras: sentinelPayload
            )
            if let e = entry {
                XCTAssertFalse(
                    e.primaryText.contains(sentinel),
                    "\(kind) leaked sentinel in primaryText: \(e.primaryText)")
                XCTAssertFalse(
                    e.secondaryText?.contains(sentinel) == true,
                    "\(kind) leaked sentinel in secondaryText: \(e.secondaryText ?? "")")
            }
        }
    }

    // MARK: - Track-6 P6 — IDE surface cap

    func test_p6_vscodeActiveDocChanged() {
        // VSCode bundle — "VSCode: <workspace> — <file>"
        let entry = map(
            kind: "vscode_active_doc_changed", signalType: "attention",
            bundleID: "com.microsoft.VSCode",
            extras: [
                "workspace_name": "leaf",
                "file_basename": "Foo.swift",
                "ide_bundle_id": "com.microsoft.VSCode",
            ]
        )
        XCTAssertEqual(entry?.primaryText, "VSCode: leaf — Foo.swift")
        XCTAssertEqual(entry?.provider, .local)
    }

    func test_p6_cursorActiveDocChanged() {
        // Cursor bundle — app name derived via vscodeAppName(forBundleID:)
        let entry = map(
            kind: "vscode_active_doc_changed", signalType: "attention",
            bundleID: "com.todesktop.230313mzl4w4u92",
            extras: [
                "workspace_name": "leaf",
                "file_basename": "Foo.swift",
                "ide_bundle_id": "com.todesktop.230313mzl4w4u92",
            ]
        )
        XCTAssertEqual(entry?.primaryText, "Cursor: leaf — Foo.swift")
    }

    func test_p6_vscodeWorkspaceOpened() {
        let entry = map(
            kind: "vscode_workspace_opened", signalType: "attention",
            bundleID: "com.microsoft.VSCode",
            extras: [
                "workspace_name": "leaf-docs",
                "ide_bundle_id": "com.microsoft.VSCode",
            ]
        )
        XCTAssertEqual(entry?.primaryText, "Opened workspace: leaf-docs")
    }

    func test_p6_jetbrainsRecentProjectObserved() {
        // JetBrains recent project — primary "JetBrains: <project>", secondary version dir
        let entry = map(
            kind: "jetbrains_recent_project_observed", signalType: "attention",
            bundleID: "com.jetbrains.pycharm",
            extras: [
                "project_name": "ml-research",
                "ide_version_dir": "PyCharm2025.1",
                "ide_bundle_id": "com.jetbrains.pycharm",
            ]
        )
        XCTAssertEqual(entry?.primaryText, "JetBrains: ml-research")
        XCTAssertEqual(entry?.secondaryText, "PyCharm2025.1")
    }

    func test_p6_ideWindowTitleObservedReturnsNil() {
        // ide_window_title_observed is debug-only — intentionally NOT in the
        // whitelist and NOT in the mapLocalOS switch. Must return nil.
        let entry = map(
            kind: "ide_window_title_observed", signalType: "attention",
            bundleID: "com.microsoft.VSCode",
            extras: ["raw_title": "leaf — ActivityFeedMapper.swift — VSCode"]
        )
        XCTAssertNil(entry, "ide_window_title_observed is debug-only and must not render")
    }
}
