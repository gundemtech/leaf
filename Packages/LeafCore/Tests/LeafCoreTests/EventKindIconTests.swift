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
        // S1 (9) + S2 (14) + S3 (10 visible — 3 in skippedKinds)
        //   + Track-6 P5 (3 — zoom started/ended/calendar_linked) = 36.
        XCTAssertEqual(ActivityFeedMapper.trackFourLocalOSKinds.count, 36)
    }
}
