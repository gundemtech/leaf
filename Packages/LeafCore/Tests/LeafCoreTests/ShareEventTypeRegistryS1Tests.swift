import XCTest

@testable import LeafCore

/// Phase Track-4 S1 — verifies registry expansion: 9 new event_kind cases all
/// land with `defaultEnabled: false` per ADR-020 (capture-everything locally,
/// share-selectively).
final class ShareEventTypeRegistryS1Tests: XCTestCase {

    /// #1 — 9 new S1 cases present in `ShareEventTypeKey`.
    func testS1KeysRegistered() {
        let s1RawValues: Set<String> = [
            "meeting_state_entered", "meeting_state_exited",
            "focus_mode_enabled", "focus_mode_disabled",
            "system_locked", "system_unlocked", "system_slept", "system_woke",
            "space_switched",
        ]
        let allRawValues = Set(ShareEventTypeKey.allCases.map { $0.rawValue })
        for raw in s1RawValues {
            XCTAssertTrue(
                allRawValues.contains(raw),
                "S1 raw value \(raw) must appear in ShareEventTypeKey"
            )
        }
    }

    /// #2 — total registry size is exactly 125 (116 baseline + 9 new).
    /// Track 4 S2 grew it 125 → 139. Track 4 S3 grew it 139 → 152.
    /// Track-6 P1 168 → P3 176 → P4 182 → P2 188 → P5 191.
    func testRegistrySizeIs125() {
        XCTAssertEqual(ShareEventTypeKey.allCases.count, 198)
        XCTAssertEqual(ShareEventTypeDefaults.all.count, 198)
    }

    /// #3 — every new S1 key defaults to OFF (ADR-020).
    func testS1KeysAllDefaultOff() {
        let s1RawValues: Set<String> = [
            "meeting_state_entered", "meeting_state_exited",
            "focus_mode_enabled", "focus_mode_disabled",
            "system_locked", "system_unlocked", "system_slept", "system_woke",
            "space_switched",
        ]
        for entry in ShareEventTypeDefaults.all where s1RawValues.contains(entry.key.rawValue) {
            XCTAssertFalse(
                entry.defaultEnabled,
                "S1 key \(entry.key.rawValue) must default to OFF per ADR-020"
            )
        }
    }
}
