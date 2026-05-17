//
//  GitHubCodespacesDiffTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D2 — Task 8. Pure-helper tests for
//  GitHubWarmCollector.codespacesDiff(prior:current:).
//
//  Codespace tracking is name-keyed (codespaceName is GitHub's stable handle).
//  Output partitions: created (new name), started (state transitioned to
//  Available), stopped (state transitioned to Shutdown), deleted (name absent
//  from current). One snapshot may yield multiple rows when a brand-new
//  codespace appears already in the Available state — the spec lists those
//  cases under created (state transition handled by collector tier in a
//  subsequent tick).
//

import XCTest

@testable import LeafCore

final class GitHubCodespacesDiffTests: XCTestCase {

    private func cs(
        name: String,
        repo: String = "owner/repo",
        state: String = "Shutdown",
        createdAt: Int64 = 1_000,
        lastUsed: Int64? = nil
    ) -> GitHubCodespaceSnapshot {
        GitHubCodespaceSnapshot(
            codespaceName: name,
            repoFullName: repo,
            state: state,
            createdAtMs: createdAt,
            lastUsedAtMs: lastUsed
        )
    }

    func testIdenticalInput_emitsNothing() {
        let snap = [cs(name: "musical-octo", state: "Available")]
        let (c, st, sp, d) = GitHubWarmCollector.codespacesDiff(prior: snap, current: snap)
        XCTAssertTrue(c.isEmpty)
        XCTAssertTrue(st.isEmpty)
        XCTAssertTrue(sp.isEmpty)
        XCTAssertTrue(d.isEmpty)
    }

    func testNewCodespace_emitsCreatedRow() {
        let prior: [GitHubCodespaceSnapshot] = []
        let current = [cs(name: "musical-octo", state: "Shutdown")]
        let (c, st, sp, d) = GitHubWarmCollector.codespacesDiff(prior: prior, current: current)
        XCTAssertEqual(c.map(\.codespaceName), ["musical-octo"])
        XCTAssertTrue(st.isEmpty)
        XCTAssertTrue(sp.isEmpty)
        XCTAssertTrue(d.isEmpty)
    }

    func testStateTransitionToAvailable_emitsStartedRow() {
        let prior = [cs(name: "musical-octo", state: "Shutdown")]
        let current = [cs(name: "musical-octo", state: "Available")]
        let (c, st, sp, d) = GitHubWarmCollector.codespacesDiff(prior: prior, current: current)
        XCTAssertTrue(c.isEmpty)
        XCTAssertEqual(st.map(\.codespaceName), ["musical-octo"])
        XCTAssertTrue(sp.isEmpty)
        XCTAssertTrue(d.isEmpty)
    }

    func testStateTransitionToShutdown_emitsStoppedRow() {
        let prior = [cs(name: "musical-octo", state: "Available")]
        let current = [cs(name: "musical-octo", state: "Shutdown")]
        let (c, st, sp, d) = GitHubWarmCollector.codespacesDiff(prior: prior, current: current)
        XCTAssertTrue(c.isEmpty)
        XCTAssertTrue(st.isEmpty)
        XCTAssertEqual(sp.map(\.codespaceName), ["musical-octo"])
        XCTAssertTrue(d.isEmpty)
    }

    func testRemovedCodespace_emitsDeletedRow() {
        let prior = [cs(name: "musical-octo", state: "Available")]
        let current: [GitHubCodespaceSnapshot] = []
        let (c, st, sp, d) = GitHubWarmCollector.codespacesDiff(prior: prior, current: current)
        XCTAssertTrue(c.isEmpty)
        XCTAssertTrue(st.isEmpty)
        XCTAssertTrue(sp.isEmpty)
        XCTAssertEqual(d.map(\.codespaceName), ["musical-octo"])
    }

    func testTransientStates_doNotEmit() {
        // Provisioning / Queued / Building / Starting transitions should not
        // count as started or stopped — only terminal Available / Shutdown.
        let prior = [cs(name: "x", state: "Provisioning")]
        let current = [cs(name: "x", state: "Building")]
        let (c, st, sp, d) = GitHubWarmCollector.codespacesDiff(prior: prior, current: current)
        XCTAssertTrue(c.isEmpty)
        XCTAssertTrue(st.isEmpty)
        XCTAssertTrue(sp.isEmpty)
        XCTAssertTrue(d.isEmpty)
    }

    func testOutputSortedByName() {
        let prior: [GitHubCodespaceSnapshot] = []
        let current = [cs(name: "zebra"), cs(name: "alpha"), cs(name: "mango")]
        let (c, _, _, _) = GitHubWarmCollector.codespacesDiff(prior: prior, current: current)
        XCTAssertEqual(c.map(\.codespaceName), ["alpha", "mango", "zebra"])
    }
}
