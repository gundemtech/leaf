import XCTest

@testable import LeafCore

final class SameTaskMatcherTests: XCTestCase {
    func snap(
        _ name: String, linearID: String? = nil, branch: String? = nil,
        repo: String? = "leaf", at ms: Int64 = 1000
    ) -> TeammateSnapshot {
        TeammateSnapshot(
            memberID: name, displayName: name, linearID: linearID, branch: branch,
            repo: repo, currentApp: "Xcode", lastActivityAtMs: ms)
    }

    func testEmptyIdentityReturnsEmpty() {
        let me = TaskIdentity()
        let matches = SameTaskMatcher.match(
            myIdentity: me, teammates: [snap("a", linearID: "LEAF-1")],
            rule: .hierarchical)
        XCTAssertEqual(matches, [])
    }

    func testSameLinearIssueMatch() {
        let me = TaskIdentity(linearID: "LEAF-204", branch: "feat", repo: "leaf")
        let teammates = [snap("anton", linearID: "LEAF-204", branch: "diff")]
        let matches = SameTaskMatcher.match(myIdentity: me, teammates: teammates, rule: .hierarchical)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].confidence, .onSameLinearIssue)
        XCTAssertEqual(matches[0].contextLabel, "on LEAF-204")
    }

    func testSameBranchMatchOnlyWhenNeitherHasLinearID() {
        let me = TaskIdentity(branch: "feature/track-8-home", repo: "leaf")
        let teammates = [snap("anton", branch: "feature/track-8-home")]
        let matches = SameTaskMatcher.match(myIdentity: me, teammates: teammates, rule: .hierarchical)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].confidence, .onSameBranch)
        XCTAssertEqual(matches[0].contextLabel, "same branch")
    }

    func testAdjacentBranchMatchWith3SharedSegments() {
        let me = TaskIdentity(branch: "feature/track-8-home", repo: "leaf")
        let teammates = [snap("anton", branch: "feature/track-8-analytics")]
        let matches = SameTaskMatcher.match(myIdentity: me, teammates: teammates, rule: .hierarchical)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].confidence, .onAdjacentBranch)
        XCTAssertEqual(matches[0].contextLabel, "adjacent branch")
    }

    func testAdjacentBranchThresholdFails() {
        // Only "feature" prefix matches (1 segment); rest divergent.
        let me = TaskIdentity(branch: "feature/track-8-home", repo: "leaf")
        let teammates = [snap("anton", branch: "feature/track-9-foo")]
        let matches = SameTaskMatcher.match(myIdentity: me, teammates: teammates, rule: .hierarchical)
        XCTAssertEqual(matches, [])
    }

    func testDifferentRepoSkipsAdjacent() {
        let me = TaskIdentity(branch: "feature/track-8-home", repo: "leaf")
        let teammates = [snap("anton", branch: "feature/track-8-home", repo: "other")]
        let matches = SameTaskMatcher.match(myIdentity: me, teammates: teammates, rule: .hierarchical)
        XCTAssertEqual(matches, [])
    }

    func testMixedCohortSortByConfidenceThenTime() {
        let me = TaskIdentity(linearID: "LEAF-204", branch: "feature/track-8-home", repo: "leaf")
        let teammates = [
            snap("zed", linearID: "LEAF-OTHER", branch: "feature/track-8-foo", at: 5000),  // adjacent
            snap("anton", linearID: "LEAF-204", at: 1000),  // same issue, older
            snap("maria", linearID: "LEAF-204", at: 2000),  // same issue, newer
        ]
        let matches = SameTaskMatcher.match(myIdentity: me, teammates: teammates, rule: .hierarchical)
        XCTAssertEqual(matches.count, 3)
        XCTAssertEqual(matches[0].memberID, "maria")  // same issue, newer
        XCTAssertEqual(matches[1].memberID, "anton")  // same issue, older
        XCTAssertEqual(matches[2].memberID, "zed")  // adjacent
    }

    func testMyLinearIDPresentSkipsRule2EvenOnIdenticalBranch() {
        // I have LEAF-204; teammate has no LEAF-ID but identical branch.
        // Rule 1 fires only if both have IDs. Rule 2 requires both nil.
        // Result: no match.
        let me = TaskIdentity(linearID: "LEAF-204", branch: "feature/x", repo: "leaf")
        let teammates = [snap("anton", linearID: nil, branch: "feature/x")]
        let matches = SameTaskMatcher.match(myIdentity: me, teammates: teammates, rule: .hierarchical)
        XCTAssertEqual(matches, [], "rule 1 needs both sides to have IDs; rule 2 needs both nil; this gap → skip")
    }
}
