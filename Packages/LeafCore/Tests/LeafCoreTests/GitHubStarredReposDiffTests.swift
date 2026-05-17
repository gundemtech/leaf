//
//  GitHubStarredReposDiffTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D2 — Task 10. Pure-helper tests for
//  `GitHubColdCollector.starredDiff(prior:current:)`.
//

import XCTest

@testable import LeafCore

final class GitHubStarredReposDiffTests: XCTestCase {
    func testEmptyEmpty() {
        let r = GitHubColdCollector.starredDiff(prior: [], current: [])
        XCTAssertTrue(r.starred.isEmpty)
        XCTAssertTrue(r.unstarred.isEmpty)
    }

    func testBootstrapAllStarred() {
        let r = GitHubColdCollector.starredDiff(
            prior: [],
            current: ["octo/repo", "leaf/leaf"]
        )
        XCTAssertEqual(r.starred.sorted(), ["leaf/leaf", "octo/repo"])
        XCTAssertTrue(r.unstarred.isEmpty)
    }

    func testAllUnstarred() {
        let r = GitHubColdCollector.starredDiff(
            prior: ["a/b", "c/d"],
            current: []
        )
        XCTAssertTrue(r.starred.isEmpty)
        XCTAssertEqual(r.unstarred.sorted(), ["a/b", "c/d"])
    }

    func testMixedStarUnstar() {
        let r = GitHubColdCollector.starredDiff(
            prior: ["a/b", "c/d"],
            current: ["c/d", "e/f"]
        )
        XCTAssertEqual(r.starred.sorted(), ["e/f"])
        XCTAssertEqual(r.unstarred.sorted(), ["a/b"])
    }

    func testUnchanged() {
        let r = GitHubColdCollector.starredDiff(
            prior: ["a/b", "c/d"],
            current: ["a/b", "c/d"]
        )
        XCTAssertTrue(r.starred.isEmpty)
        XCTAssertTrue(r.unstarred.isEmpty)
    }
}
