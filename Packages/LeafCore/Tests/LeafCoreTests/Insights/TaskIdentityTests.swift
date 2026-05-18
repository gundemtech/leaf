import XCTest

@testable import LeafCore

final class TaskIdentityTests: XCTestCase {
    func testIsEmptyWhenAllNil() {
        let id = TaskIdentity()
        XCTAssertTrue(id.isEmpty)
    }

    func testNotEmptyWhenAnyFieldSet() {
        XCTAssertFalse(TaskIdentity(linearID: "LEAF-1").isEmpty)
        XCTAssertFalse(TaskIdentity(branch: "main").isEmpty)
        XCTAssertFalse(TaskIdentity(repo: "leaf").isEmpty)
        XCTAssertFalse(TaskIdentity(workspacePath: "/x").isEmpty)
    }

    func testEquatable() {
        let a = TaskIdentity(linearID: "LEAF-1", branch: "feat", repo: "r", workspacePath: "/p")
        let b = TaskIdentity(linearID: "LEAF-1", branch: "feat", repo: "r", workspacePath: "/p")
        let c = TaskIdentity(linearID: "LEAF-2", branch: "feat", repo: "r", workspacePath: "/p")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testTeammateMatchConfidencePriority() {
        XCTAssertEqual(MatchConfidence.onSameLinearIssue.rawValue, "onSameLinearIssue")
        XCTAssertEqual(MatchConfidence.onSameBranch.rawValue, "onSameBranch")
        XCTAssertEqual(MatchConfidence.onAdjacentBranch.rawValue, "onAdjacentBranch")
        XCTAssertLessThan(
            MatchConfidence.onSameLinearIssue.sortRank,
            MatchConfidence.onSameBranch.sortRank)
        XCTAssertLessThan(
            MatchConfidence.onSameBranch.sortRank,
            MatchConfidence.onAdjacentBranch.sortRank)
    }

    func testTeammateSnapshotEquatable() {
        let s1 = TeammateSnapshot(
            memberID: "m1", displayName: "Anton", linearID: "LEAF-1",
            branch: "b", repo: "r", currentApp: "Xcode", lastActivityAtMs: 1000)
        let s2 = TeammateSnapshot(
            memberID: "m1", displayName: "Anton", linearID: "LEAF-1",
            branch: "b", repo: "r", currentApp: "Xcode", lastActivityAtMs: 1000)
        XCTAssertEqual(s1, s2)
    }
}
