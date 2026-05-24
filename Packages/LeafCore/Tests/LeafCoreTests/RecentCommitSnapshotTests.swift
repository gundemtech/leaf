import XCTest
@testable import LeafCore

final class RecentCommitSnapshotTests: XCTestCase {
    func testRoundTripInit() {
        let s = RecentCommitSnapshot(subject: "fix typo", branch: "main", atMs: 1715800000000)
        XCTAssertEqual(s.subject, "fix typo")
        XCTAssertEqual(s.branch, "main")
        XCTAssertEqual(s.atMs, 1715800000000)
    }

    func testBranchOptional() {
        let s = RecentCommitSnapshot(subject: "x", branch: nil, atMs: 0)
        XCTAssertNil(s.branch)
    }

    func testEquatable() {
        let a = RecentCommitSnapshot(subject: "x", branch: "main", atMs: 100)
        let b = RecentCommitSnapshot(subject: "x", branch: "main", atMs: 100)
        let c = RecentCommitSnapshot(subject: "x", branch: "main", atMs: 101)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
