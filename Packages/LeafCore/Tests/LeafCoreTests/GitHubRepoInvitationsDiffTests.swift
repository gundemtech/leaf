//
//  GitHubRepoInvitationsDiffTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D2 — Task 8. Pure-helper tests for
//  GitHubWarmCollector.invitationsDiff(prior:current:).
//
//  Repo invitations are invitation_id keyed. Output partitions:
//    - received: invitation_id present in current but absent from prior
//      (new pending invite landed in inbox)
//    - accepted: invitation_id present in prior but absent from current
//      (invitation either accepted or declined; we treat absence as
//      accepted/cleared per spec — explicit decline event lives in cold)
//

import XCTest

@testable import LeafCore

final class GitHubRepoInvitationsDiffTests: XCTestCase {

    private func inv(
        id: String,
        repo: String = "owner/repo",
        from: String = "alice",
        invitedAt: Int64 = 1_000
    ) -> GitHubRepoInvitationSnapshot {
        GitHubRepoInvitationSnapshot(
            invitationID: id,
            repoFullName: repo,
            inviterLogin: from,
            invitedAtMs: invitedAt
        )
    }

    func testIdenticalInput_emitsNothing() {
        let snap = [inv(id: "i1")]
        let (r, a) = GitHubWarmCollector.invitationsDiff(prior: snap, current: snap)
        XCTAssertTrue(r.isEmpty)
        XCTAssertTrue(a.isEmpty)
    }

    func testNewInvitation_emitsReceivedRow() {
        let prior: [GitHubRepoInvitationSnapshot] = []
        let current = [inv(id: "i1", repo: "octo/cat")]
        let (r, a) = GitHubWarmCollector.invitationsDiff(prior: prior, current: current)
        XCTAssertEqual(r.map(\.invitationID), ["i1"])
        XCTAssertEqual(r[0].repoFullName, "octo/cat")
        XCTAssertTrue(a.isEmpty)
    }

    func testRemovedInvitation_emitsAcceptedRow() {
        let prior = [inv(id: "i1"), inv(id: "i2")]
        let current = [inv(id: "i1")]
        let (r, a) = GitHubWarmCollector.invitationsDiff(prior: prior, current: current)
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(a.map(\.invitationID), ["i2"])
    }

    func testCombinedReceivedAndAccepted() {
        let prior = [inv(id: "i1", repo: "old/repo"), inv(id: "i2", repo: "still/here")]
        let current = [inv(id: "i2", repo: "still/here"), inv(id: "i3", repo: "new/repo")]
        let (r, a) = GitHubWarmCollector.invitationsDiff(prior: prior, current: current)
        XCTAssertEqual(r.map(\.invitationID), ["i3"])
        XCTAssertEqual(a.map(\.invitationID), ["i1"])
    }

    func testOutputSortedByInvitationID() {
        let prior: [GitHubRepoInvitationSnapshot] = []
        let current = [inv(id: "i3"), inv(id: "i1"), inv(id: "i2")]
        let (r, _) = GitHubWarmCollector.invitationsDiff(prior: prior, current: current)
        XCTAssertEqual(r.map(\.invitationID), ["i1", "i2", "i3"])
    }
}
