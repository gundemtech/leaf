//
//  GitHubGistsDiffTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D2 — Task 8. Pure-helper tests for
//  GitHubWarmCollector.gistsDiff(prior:current:).
//
//  Output is partitioned into three lists: created (gistID present in
//  current but not prior), updated (gistID in both, updatedAtMs differs),
//  deleted (gistID in prior but absent from current). Bootstrap discipline
//  (caller passes empty prior) lives in the collector tier.
//

import XCTest

@testable import LeafCore

final class GitHubGistsDiffTests: XCTestCase {

    private func gist(
        id: String,
        description: String = "",
        isPublic: Bool = true,
        createdAt: Int64 = 1_000,
        updatedAt: Int64 = 1_000
    ) -> GitHubGistSnapshot {
        GitHubGistSnapshot(
            gistID: id,
            description: description,
            isPublic: isPublic,
            createdAtMs: createdAt,
            updatedAtMs: updatedAt
        )
    }

    func testIdenticalInput_emitsNothing() {
        let snap = [gist(id: "g1", description: "alpha", updatedAt: 100)]
        let (c, u, d) = GitHubWarmCollector.gistsDiff(prior: snap, current: snap)
        XCTAssertEqual(c.count, 0)
        XCTAssertEqual(u.count, 0)
        XCTAssertEqual(d.count, 0)
    }

    func testNewGist_emitsCreatedRow() {
        let prior: [GitHubGistSnapshot] = []
        let current = [gist(id: "g1", description: "alpha")]
        let (c, u, d) = GitHubWarmCollector.gistsDiff(prior: prior, current: current)
        XCTAssertEqual(c.map(\.gistID), ["g1"])
        XCTAssertTrue(u.isEmpty)
        XCTAssertTrue(d.isEmpty)
    }

    func testUpdatedAtChange_emitsUpdatedRow() {
        let prior = [gist(id: "g1", description: "alpha", updatedAt: 100)]
        let current = [gist(id: "g1", description: "beta", updatedAt: 200)]
        let (c, u, d) = GitHubWarmCollector.gistsDiff(prior: prior, current: current)
        XCTAssertTrue(c.isEmpty)
        XCTAssertEqual(u.map(\.gistID), ["g1"])
        XCTAssertEqual(u[0].updatedAtMs, 200)
        XCTAssertTrue(d.isEmpty)
    }

    func testRemovedGist_emitsDeletedRow() {
        let prior = [gist(id: "g1"), gist(id: "g2")]
        let current = [gist(id: "g1")]
        let (c, u, d) = GitHubWarmCollector.gistsDiff(prior: prior, current: current)
        XCTAssertTrue(c.isEmpty)
        XCTAssertTrue(u.isEmpty)
        XCTAssertEqual(d.map(\.gistID), ["g2"])
    }

    func testCombinedCreateUpdateDelete() {
        let prior = [
            gist(id: "g1", description: "alpha", updatedAt: 100),
            gist(id: "g2", description: "beta", updatedAt: 100),
        ]
        let current = [
            gist(id: "g1", description: "alpha", updatedAt: 100),  // unchanged
            gist(id: "g2", description: "beta-v2", updatedAt: 200),  // updated
            gist(id: "g3", description: "gamma", updatedAt: 300),  // created
        ]
        let (c, u, d) = GitHubWarmCollector.gistsDiff(prior: prior, current: current)
        XCTAssertEqual(c.map(\.gistID), ["g3"])
        XCTAssertEqual(u.map(\.gistID), ["g2"])
        XCTAssertTrue(d.isEmpty)
    }

    func testOutputSortedByGistID() {
        let prior: [GitHubGistSnapshot] = []
        let current = [
            gist(id: "g3"), gist(id: "g1"), gist(id: "g2"),
        ]
        let (c, _, _) = GitHubWarmCollector.gistsDiff(prior: prior, current: current)
        XCTAssertEqual(c.map(\.gistID), ["g1", "g2", "g3"])
    }

    func testSameUpdatedAt_descriptionChange_isNotUpdated() {
        // Spec: "updated" means updatedAtMs differs. If GitHub returned same
        // updatedAt with mutated description, we trust the timestamp and skip.
        let prior = [gist(id: "g1", description: "alpha", updatedAt: 100)]
        let current = [gist(id: "g1", description: "beta", updatedAt: 100)]
        let (c, u, d) = GitHubWarmCollector.gistsDiff(prior: prior, current: current)
        XCTAssertTrue(c.isEmpty)
        XCTAssertTrue(u.isEmpty)
        XCTAssertTrue(d.isEmpty)
    }
}
