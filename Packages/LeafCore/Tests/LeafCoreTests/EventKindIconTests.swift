// Phase Track-4 S4 — EventKindIcon parity tests. Locks in:
// 1) Every visible Track-4 kind has a non-nil SF Symbol mapping.
// 2) Paired kinds intentionally share a symbol (copy disambiguates).
// 3) Sentinel checks catch accidental rename.
// 4) Set size guard catches silent additions / removals to the whitelist.

import XCTest
@testable import LeafCore

final class EventKindIconTests: XCTestCase {
    func testAllTrack4VisibleKindsMapped() {
        // Mirror trackFourLocalOSKinds — every visible kind must have an icon.
        for kind in ActivityFeedMapper.trackFourLocalOSKinds {
            XCTAssertNotNil(
                EventKindIcon.symbol(for: kind),
                "Missing SF Symbol mapping for \(kind)"
            )
        }
    }

    func testUnknownKindReturnsNil() {
        XCTAssertNil(EventKindIcon.symbol(for: "totally_unknown_kind"))
    }

    func testPairedKindsShareSymbol() {
        XCTAssertEqual(
            EventKindIcon.symbol(for: "meeting_state_entered"),
            EventKindIcon.symbol(for: "meeting_state_exited")
        )
        XCTAssertEqual(
            EventKindIcon.symbol(for: "system_locked"),
            EventKindIcon.symbol(for: "system_unlocked")
        )
        XCTAssertEqual(
            EventKindIcon.symbol(for: "mic_in_use_entered"),
            EventKindIcon.symbol(for: "mic_in_use_exited")
        )
        XCTAssertEqual(
            EventKindIcon.symbol(for: "display_connected"),
            EventKindIcon.symbol(for: "display_disconnected")
        )
    }

    func testSpecificSymbols() {
        // Sentinel checks — catch accidental rename.
        XCTAssertEqual(EventKindIcon.symbol(for: "screenshot_taken"), "camera.viewfinder")
        XCTAssertEqual(EventKindIcon.symbol(for: "music_track_changed"), "music.note")
        XCTAssertEqual(EventKindIcon.symbol(for: "vpn_state_changed"), "shield.lefthalf.filled")
    }

    func testTrack4LocalOSKindsSetSizeUnchanged() {
        // Guards against silent additions / removals from the whitelist.
        // S1 (9) + S2 (14) + S3 (10 visible — 3 in skippedKinds) + P3 (8) = 41.
        XCTAssertEqual(ActivityFeedMapper.trackFourLocalOSKinds.count, 41)
    }

    // MARK: - Track-6 P1 — Claude Code

    /// Every visible `claude_*` kind has an SF Symbol mapping.
    /// Parity with `trackFourLocalOSKinds` precedent — adding a new kind to
    /// `ActivityFeedMapper.claudeCodeAIKinds` without an icon mapping triggers
    /// failure here.
    func testAllClaudeCodeVisibleKindsMapped() {
        for kind in ActivityFeedMapper.claudeCodeAIKinds {
            XCTAssertNotNil(
                EventKindIcon.symbol(for: kind),
                "Missing SF Symbol mapping for \(kind)"
            )
        }
    }

    /// Retroactive pair share the same symbol (sparkles) — copy in
    /// `ActivityFeedMapper.mapAI` disambiguates.
    func testRetroactivePairShareSparkles() {
        XCTAssertEqual(
            EventKindIcon.symbol(for: "tool_use"),
            EventKindIcon.symbol(for: "user_prompt")
        )
        XCTAssertEqual(EventKindIcon.symbol(for: "tool_use"), "sparkles")
    }

    /// Sentinel — catches accidental rename across builds.
    func testClaudeCodeSpecificSymbols() {
        XCTAssertEqual(EventKindIcon.symbol(for: "claude_bash_executed"), "terminal")
        XCTAssertEqual(EventKindIcon.symbol(for: "claude_subagent_dispatched"), "person.2.circle")
        XCTAssertEqual(EventKindIcon.symbol(for: "claude_session_started"), "play.circle")
    }

    /// Guards against silent additions / removals from the whitelist.
    /// 2 retroactive + 4 session lifecycle (visible) + 8 per-tool = 14.
    func testClaudeCodeAIKindsSetSizeUnchanged() {
        XCTAssertEqual(ActivityFeedMapper.claudeCodeAIKinds.count, 14)
    }
}
