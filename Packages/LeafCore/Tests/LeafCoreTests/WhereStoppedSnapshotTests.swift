import XCTest

@testable import LeafCore

final class WhereStoppedSnapshotTests: XCTestCase {
    func testMemberwiseInit() {
        let s = WhereStoppedSnapshot(
            id: 1,
            generatedAtMs: 1_700_000_000_000,
            anchorEventId: 42,
            excerpt: "You were editing 5 files and reviewing 3 PRs",
            wipSignals: ["5 files", "3 PRs"]
        )
        XCTAssertEqual(s.id, 1)
        XCTAssertEqual(s.wipSignals.count, 2)
        XCTAssertEqual(s.anchorEventId, 42)
    }

    func testEmptyWipSignalsAllowed() {
        let s = WhereStoppedSnapshot(
            id: 1, generatedAtMs: 0, anchorEventId: nil,
            excerpt: "Empty pulse", wipSignals: []
        )
        XCTAssertTrue(s.wipSignals.isEmpty)
    }

    func testAnchorEventIdNilAllowed() {
        let s = WhereStoppedSnapshot(
            id: 1, generatedAtMs: 0, anchorEventId: nil,
            excerpt: "x", wipSignals: []
        )
        XCTAssertNil(s.anchorEventId)
    }

    func testHashable() {
        let a = WhereStoppedSnapshot(
            id: 1, generatedAtMs: 0, anchorEventId: nil,
            excerpt: "x", wipSignals: ["a"])
        let b = WhereStoppedSnapshot(
            id: 1, generatedAtMs: 0, anchorEventId: nil,
            excerpt: "x", wipSignals: ["a"])
        XCTAssertEqual(Set([a, b]).count, 1)
    }

    func testSendableConformance() {
        let _: any Sendable = WhereStoppedSnapshot(
            id: 1, generatedAtMs: 0, anchorEventId: nil,
            excerpt: "x", wipSignals: []
        )
    }

    // MARK: - Track-9 T7 PT-1..PT-3

    func test_PT1_whereStopped_backwardCompatInit_5arg() {
        // Existing 5-arg init must continue to compile (defaulted-init pattern).
        let s = WhereStoppedSnapshot(
            id: 1,
            generatedAtMs: 1_700_000_000_000,
            anchorEventId: 42,
            excerpt: "x",
            wipSignals: ["commitWip"]
        )
        XCTAssertNil(s.anchorFilePath)
        XCTAssertNil(s.anchorLine)
        XCTAssertNil(s.recentLastCommit)
    }

    func test_PT2_whereStopped_fullInit_roundtripsAllFields() {
        let commit = RecentCommitSnapshot(subject: "wf: HIG sweep", branch: "main", atMs: 1_700_000_100_000)
        let s = WhereStoppedSnapshot(
            id: 1,
            generatedAtMs: 1_700_000_000_000,
            anchorEventId: 99,
            excerpt: "e",
            wipSignals: ["midEdit"],
            anchorFilePath: "Foo.swift",
            anchorLine: 142,
            recentLastCommit: commit
        )
        XCTAssertEqual(s.anchorFilePath, "Foo.swift")
        XCTAssertEqual(s.anchorLine, 142)
        XCTAssertEqual(s.recentLastCommit?.subject, "wf: HIG sweep")

        // Equatable + Hashable round-trip with full init.
        let s2 = s
        XCTAssertEqual(s, s2)
        XCTAssertEqual(Set([s, s2]).count, 1)
    }

    func test_PT3_whereStopped_optionalFields_defaultNil() {
        let s = WhereStoppedSnapshot(
            id: 1,
            generatedAtMs: 0,
            anchorEventId: nil,
            excerpt: "x",
            wipSignals: []
        )
        XCTAssertNil(s.anchorFilePath)
        XCTAssertNil(s.anchorLine)
        XCTAssertNil(s.recentLastCommit)
    }
}
