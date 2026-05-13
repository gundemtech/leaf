//
//  GitHubSecurityAlertsDiffTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D2 — Task 10. Pure-helper tests for
//  `GitHubColdCollector.securityAlertsDiff(prior:current:)` covering composite
//  key (kind, repoFullName, alertNumber), set-difference base case, and the
//  state-transition extension (open→fixed = resolved; resolved→open = re-observed).
//

import XCTest
@testable import LeafCore

final class GitHubSecurityAlertsDiffTests: XCTestCase {
    private func alert(
        kind: GitHubSecurityAlertSnapshot.Kind = .secret,
        repo: String = "octo/repo",
        number: Int = 1,
        state: String = "open",
        rule: String = "CVE-2024-0001",
        package: String? = nil,
        severity: String = "high"
    ) -> GitHubSecurityAlertSnapshot {
        GitHubSecurityAlertSnapshot(
            kind: kind, repoFullName: repo, alertNumber: number,
            severity: severity, rule: rule, packageName: package, state: state,
            createdAtMs: 1, updatedAtMs: 2
        )
    }

    func testEmptyEmpty() {
        let r = GitHubColdCollector.securityAlertsDiff(prior: [], current: [])
        XCTAssertTrue(r.observed.isEmpty)
        XCTAssertTrue(r.resolved.isEmpty)
    }

    func testNewAlertObserved() {
        let r = GitHubColdCollector.securityAlertsDiff(
            prior: [],
            current: [alert(number: 1, state: "open")]
        )
        XCTAssertEqual(r.observed.count, 1)
        XCTAssertEqual(r.observed.first?.alertNumber, 1)
        XCTAssertTrue(r.resolved.isEmpty)
    }

    func testAlertDisappearedResolved() {
        let r = GitHubColdCollector.securityAlertsDiff(
            prior: [alert(number: 2, state: "open")],
            current: []
        )
        XCTAssertEqual(r.resolved.count, 1)
        XCTAssertEqual(r.resolved.first?.alertNumber, 2)
        XCTAssertTrue(r.observed.isEmpty)
    }

    func testStateTransitionOpenToFixedEmitsResolved() {
        let r = GitHubColdCollector.securityAlertsDiff(
            prior: [alert(number: 7, state: "open")],
            current: [alert(number: 7, state: "fixed")]
        )
        XCTAssertEqual(r.resolved.count, 1)
        XCTAssertEqual(r.resolved.first?.state, "fixed")
        XCTAssertTrue(r.observed.isEmpty)
    }

    func testStateTransitionOpenToResolvedEmitsResolved() {
        let r = GitHubColdCollector.securityAlertsDiff(
            prior: [alert(number: 8, state: "open")],
            current: [alert(number: 8, state: "resolved")]
        )
        XCTAssertEqual(r.resolved.count, 1)
        XCTAssertTrue(r.observed.isEmpty)
    }

    func testStateTransitionOpenToDismissedEmitsResolved() {
        let r = GitHubColdCollector.securityAlertsDiff(
            prior: [alert(number: 9, state: "open")],
            current: [alert(number: 9, state: "dismissed")]
        )
        XCTAssertEqual(r.resolved.count, 1)
        XCTAssertTrue(r.observed.isEmpty)
    }

    func testReopenedFixedToOpenEmitsObserved() {
        let r = GitHubColdCollector.securityAlertsDiff(
            prior: [alert(number: 10, state: "fixed")],
            current: [alert(number: 10, state: "open")]
        )
        XCTAssertEqual(r.observed.count, 1)
        XCTAssertEqual(r.observed.first?.state, "open")
        XCTAssertTrue(r.resolved.isEmpty)
    }

    func testReopenedDismissedToOpenEmitsObserved() {
        let r = GitHubColdCollector.securityAlertsDiff(
            prior: [alert(number: 11, state: "dismissed")],
            current: [alert(number: 11, state: "open")]
        )
        XCTAssertEqual(r.observed.count, 1)
        XCTAssertTrue(r.resolved.isEmpty)
    }

    func testUnchangedAlertEmitsNothing() {
        let r = GitHubColdCollector.securityAlertsDiff(
            prior: [alert(number: 5, state: "open")],
            current: [alert(number: 5, state: "open")]
        )
        XCTAssertTrue(r.observed.isEmpty)
        XCTAssertTrue(r.resolved.isEmpty)
    }

    func testCompositeKeyDifferentRepoSameNumberAreDistinct() {
        let r = GitHubColdCollector.securityAlertsDiff(
            prior: [alert(repo: "a/b", number: 1, state: "open")],
            current: [alert(repo: "c/d", number: 1, state: "open")]
        )
        XCTAssertEqual(r.observed.count, 1)
        XCTAssertEqual(r.observed.first?.repoFullName, "c/d")
        XCTAssertEqual(r.resolved.count, 1)
        XCTAssertEqual(r.resolved.first?.repoFullName, "a/b")
    }

    func testCompositeKeyDifferentKindSameNumberAreDistinct() {
        let r = GitHubColdCollector.securityAlertsDiff(
            prior: [alert(kind: .secret, number: 1, state: "open")],
            current: [alert(kind: .code, number: 1, state: "open")]
        )
        XCTAssertEqual(r.observed.count, 1)
        XCTAssertEqual(r.observed.first?.kind, .code)
        XCTAssertEqual(r.resolved.count, 1)
        XCTAssertEqual(r.resolved.first?.kind, .secret)
    }
}
