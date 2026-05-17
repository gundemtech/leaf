import XCTest
@testable import LeafCore

final class WhereStoppedSnapshotTests: XCTestCase {
    func testMemberwiseInit() {
        let s = WhereStoppedSnapshot(
            id: 1,
            generatedAtMs: 1700000000000,
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
        let a = WhereStoppedSnapshot(id: 1, generatedAtMs: 0, anchorEventId: nil,
                                     excerpt: "x", wipSignals: ["a"])
        let b = WhereStoppedSnapshot(id: 1, generatedAtMs: 0, anchorEventId: nil,
                                     excerpt: "x", wipSignals: ["a"])
        XCTAssertEqual(Set([a, b]).count, 1)
    }

    func testSendableConformance() {
        let _: any Sendable = WhereStoppedSnapshot(
            id: 1, generatedAtMs: 0, anchorEventId: nil,
            excerpt: "x", wipSignals: []
        )
    }
}
