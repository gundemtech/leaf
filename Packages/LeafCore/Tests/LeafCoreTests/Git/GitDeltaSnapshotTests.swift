import XCTest
@testable import LeafCore

final class GitDeltaSnapshotTests: XCTestCase {
    func testEqualityRoundTrip() {
        let a = GitDeltaSnapshot(
            commitsAhead: 3, commitsBehind: 1, uncommittedCount: 2,
            mergeBase: "origin/main",
            remote: GitRemoteRef(host: "github.com", owner: "gundemtech", repo: "leaf")
        )
        let b = GitDeltaSnapshot(
            commitsAhead: 3, commitsBehind: 1, uncommittedCount: 2,
            mergeBase: "origin/main",
            remote: GitRemoteRef(host: "github.com", owner: "gundemtech", repo: "leaf")
        )
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testDefaultsAreNilForOptionalFields() {
        let s = GitDeltaSnapshot(commitsAhead: 0, commitsBehind: 0, uncommittedCount: 0)
        XCTAssertNil(s.mergeBase)
        XCTAssertNil(s.remote)
    }

    func testRemoteRefEqualityAndHash() {
        let a = GitRemoteRef(host: "github.com", owner: "x", repo: "y")
        let b = GitRemoteRef(host: "github.com", owner: "x", repo: "y")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testInequality() {
        let a = GitDeltaSnapshot(commitsAhead: 1, commitsBehind: 0, uncommittedCount: 0)
        let b = GitDeltaSnapshot(commitsAhead: 2, commitsBehind: 0, uncommittedCount: 0)
        XCTAssertNotEqual(a, b)
    }
}
