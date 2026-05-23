//
//  TeamNRowComposerTests.swift
//  Track-10 T6 — pure-function row composition for TeamNBlock. View-layer
//  body ships untested (precedent: TodayBlock / ResumeHeroBlock / NeedsYouBlock
//  / SinceLastActiveBlock — no SwiftUI snapshot infra in the app target).
//  This suite locks the composition contract that the SwiftUI body consumes.
//

import XCTest

@testable import LeafCore

final class TeamNRowComposerTests: XCTestCase {

    // MARK: - Fixture

    private func make(
        memberID: String = "m-1",
        displayName: String = "Anton Bochkarev",
        linearID: String? = nil,
        branch: String? = nil,
        repo: String? = nil,
        currentApp: String? = nil,
        lastActivityAtMs: Int64 = 1_700_000_000_000
    ) -> TeammateSnapshot {
        TeammateSnapshot(
            memberID: memberID,
            displayName: displayName,
            linearID: linearID,
            branch: branch,
            repo: repo,
            currentApp: currentApp,
            lastActivityAtMs: lastActivityAtMs
        )
    }

    // MARK: - metaLine

    func testMetaLine_BothNonNil() {
        let snap = make(branch: "feature/foo", currentApp: "Xcode")
        XCTAssertEqual(TeamNRowComposer.metaLine(snap), "Xcode · feature/foo")
    }

    func testMetaLine_OnlyApp() {
        let snap = make(currentApp: "Slack")
        XCTAssertEqual(TeamNRowComposer.metaLine(snap), "Slack")
    }

    func testMetaLine_OnlyBranch() {
        let snap = make(branch: "main")
        XCTAssertEqual(TeamNRowComposer.metaLine(snap), "main")
    }

    func testMetaLine_BothNil() {
        XCTAssertNil(TeamNRowComposer.metaLine(make()))
    }

    /// Empty-string fields treated same as nil — avoids "Xcode ·  " orphan
    /// separator when a producer emits `""` instead of nil for an unset field.
    func testMetaLine_EmptyStringSkipped() {
        let snap = make(branch: "", currentApp: "Xcode")
        XCTAssertEqual(TeamNRowComposer.metaLine(snap), "Xcode")
    }

    // MARK: - initials

    func testInitials_TwoWord() {
        XCTAssertEqual(TeamNRowComposer.initials("Dmitrii Demidov"), "DD")
    }

    func testInitials_OneWord() {
        XCTAssertEqual(TeamNRowComposer.initials("Anton"), "A")
    }

    func testInitials_Empty() {
        XCTAssertEqual(TeamNRowComposer.initials(""), "?")
    }

    func testInitials_WhitespaceOnly() {
        XCTAssertEqual(TeamNRowComposer.initials("   "), "?")
    }

    /// Three words → only first two letters used (matches WithYouOnThis precedent).
    func testInitials_ThreeWord_FirstTwoOnly() {
        XCTAssertEqual(TeamNRowComposer.initials("Anna Maria Olsen"), "AM")
    }

    // MARK: - sort

    func testSort_LastActivityDesc() {
        let oldest = make(memberID: "a", lastActivityAtMs: 1_700_000_000_000)
        let middle = make(memberID: "b", lastActivityAtMs: 1_700_000_050_000)
        let newest = make(memberID: "c", lastActivityAtMs: 1_700_000_100_000)
        let sorted = TeamNRowComposer.sorted([oldest, newest, middle])
        XCTAssertEqual(sorted.map(\.memberID), ["c", "b", "a"])
    }

    func testSort_StableOnEqualTimestamps() {
        let a = make(memberID: "a", lastActivityAtMs: 1_700_000_000_000)
        let b = make(memberID: "b", lastActivityAtMs: 1_700_000_000_000)
        let sorted = TeamNRowComposer.sorted([a, b])
        // Stable sort preserves input order on ties — guards against
        // visible-row reshuffle on tick boundaries when activity timestamps
        // are quantized by the substrate (Phase 5.4 will emit minute-aligned ms).
        XCTAssertEqual(sorted.map(\.memberID), ["a", "b"])
    }

    // MARK: - paletteIndex

    func testPaletteIndex_DeterministicWithinLaunch() {
        let first = TeamNRowComposer.paletteIndex(memberID: "m-1", paletteCount: 5)
        for _ in 0..<10 {
            XCTAssertEqual(
                TeamNRowComposer.paletteIndex(memberID: "m-1", paletteCount: 5),
                first
            )
        }
    }

    func testPaletteIndex_Bounded() {
        // Sweep a few memberIDs and assert each maps within [0, paletteCount).
        for id in ["m-1", "m-2", "m-3", "anton-bochkarev", "x"] {
            let idx = TeamNRowComposer.paletteIndex(memberID: id, paletteCount: 5)
            XCTAssertGreaterThanOrEqual(idx, 0, "id=\(id)")
            XCTAssertLessThan(idx, 5, "id=\(id)")
        }
    }

    // MARK: - a11yLabel

    func testA11yLabel_AllFields() {
        let snap = make(displayName: "Anton", branch: "feature/foo", currentApp: "Xcode")
        XCTAssertEqual(
            TeamNRowComposer.a11yLabel(snap, relativeTime: "2m ago"),
            "Anton, Xcode, feature/foo, 2m ago"
        )
    }

    func testA11yLabel_NilApp() {
        let snap = make(displayName: "Misha", branch: "main")
        XCTAssertEqual(
            TeamNRowComposer.a11yLabel(snap, relativeTime: "5m ago"),
            "Misha, main, 5m ago"
        )
    }

    func testA11yLabel_NilBranch() {
        let snap = make(displayName: "Alex", currentApp: "Slack")
        XCTAssertEqual(
            TeamNRowComposer.a11yLabel(snap, relativeTime: "8m ago"),
            "Alex, Slack, 8m ago"
        )
    }

    func testA11yLabel_BothMetaNil() {
        let snap = make(displayName: "Someone")
        XCTAssertEqual(
            TeamNRowComposer.a11yLabel(snap, relativeTime: "now"),
            "Someone, now"
        )
    }

    func testA11yLabel_EmptyStringMetaSkipped() {
        let snap = make(displayName: "Anton", branch: "", currentApp: "Xcode")
        XCTAssertEqual(
            TeamNRowComposer.a11yLabel(snap, relativeTime: "now"),
            "Anton, Xcode, now"
        )
    }

    // MARK: - visibleCap

    func testVisibleCap_FiveByDefault() {
        XCTAssertEqual(TeamNRowComposer.visibleCap, 5)
    }
}
