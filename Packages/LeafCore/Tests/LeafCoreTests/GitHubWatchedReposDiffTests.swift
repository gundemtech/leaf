//
//  GitHubWatchedReposDiffTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D2 — Task 10. Pure-helper tests for
//  `GitHubColdCollector.watchedDiff(prior:current:)`.
//

import XCTest

@testable import LeafCore

final class GitHubWatchedReposDiffTests: XCTestCase {
    func testEmptyEmpty() {
        let r = GitHubColdCollector.watchedDiff(prior: [], current: [])
        XCTAssertTrue(r.watched.isEmpty)
        XCTAssertTrue(r.unwatched.isEmpty)
    }

    func testBootstrapAllWatched() {
        let r = GitHubColdCollector.watchedDiff(
            prior: [],
            current: ["octo/repo", "leaf/leaf"]
        )
        XCTAssertEqual(r.watched.sorted(), ["leaf/leaf", "octo/repo"])
        XCTAssertTrue(r.unwatched.isEmpty)
    }

    func testAllUnwatched() {
        let r = GitHubColdCollector.watchedDiff(
            prior: ["a/b", "c/d"],
            current: []
        )
        XCTAssertTrue(r.watched.isEmpty)
        XCTAssertEqual(r.unwatched.sorted(), ["a/b", "c/d"])
    }

    func testMixedWatchUnwatch() {
        let r = GitHubColdCollector.watchedDiff(
            prior: ["a/b", "c/d"],
            current: ["c/d", "e/f"]
        )
        XCTAssertEqual(r.watched.sorted(), ["e/f"])
        XCTAssertEqual(r.unwatched.sorted(), ["a/b"])
    }

    func testUnchanged() {
        let r = GitHubColdCollector.watchedDiff(
            prior: ["a/b"],
            current: ["a/b"]
        )
        XCTAssertTrue(r.watched.isEmpty)
        XCTAssertTrue(r.unwatched.isEmpty)
    }
}
