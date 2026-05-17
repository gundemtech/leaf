// Phase Track-4 S4 — ActivityFeedMapper LocalOS branch coverage.
//
// Track-4 S1+S2+S3 landed 36 new `event_kind` discriminators под different
// signal types (`.attention` / `.context` / `.action` / `.content`) без
// `payload["source"]` key — without an explicit whitelist they fall through
// to the generic mapAttention/mapIntegration paths and either drop or render
// without semantic copy. This file pins:
//
// 1) Layer A (S1) kinds render semantically.
// 2) Privacy walkbacks — unauthorized payload fields stay out of entry text.
// 3) Skip-list noise filter for high-cadence S3 substrate metrics.
//
// S2 AppleScript surface, S3 system observers, P3 browser deep, P2 Xcode deep,
// and P6 IDE surface cap live in companion files:
//   - ActivityFeedMapperLocalOSAppleScriptTests.swift
//   - ActivityFeedMapperLocalOSSystemObserversTests.swift
//   - ActivityFeedMapperLocalOSTrack6Tests.swift
//
// Shared `map(...)` + `payloadJSON(...)` helpers live in
// ActivityFeedMapperLocalOSTestHelpers.swift.

import XCTest

@testable import LeafCore

final class ActivityFeedMapperLocalOSTests: XCTestCase {
    private typealias Support = ActivityFeedMapperLocalOSTestSupport

    private func map(
        kind: String,
        signalType: String = "context",
        bundleID: String? = nil,
        extras: [String: String] = [:]
    ) -> ActivityFeedEntry? {
        Support.map(kind: kind, signalType: signalType, bundleID: bundleID, extras: extras)
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
}
