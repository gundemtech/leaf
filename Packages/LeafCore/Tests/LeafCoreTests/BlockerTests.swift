import XCTest

@testable import LeafCore

final class BlockerTests: XCTestCase {
    // MARK: - BlockerKind enum

    func testBlockerKind_patternBlockedOnEquatable() {
        XCTAssertEqual(BlockerKind.patternBlockedOn, BlockerKind.patternBlockedOn)
    }

    func testBlockerKind_linearStuckDistinct() {
        XCTAssertNotEqual(BlockerKind.linearStuck, BlockerKind.patternBlockedOn)
    }

    func testBlockerKind_otherFallback_sameStringEqual() {
        XCTAssertEqual(BlockerKind.other("ci_failure"), BlockerKind.other("ci_failure"))
    }

    func testBlockerKind_otherFallback_differentStringUnequal() {
        XCTAssertNotEqual(BlockerKind.other("ci_failure"), BlockerKind.other("dependency"))
    }

    func testBlockerKind_otherFallback_distinctFromKnown() {
        XCTAssertNotEqual(BlockerKind.other("linear_stuck"), BlockerKind.linearStuck)
    }

    func testBlockerKind_displayName_humanizesOther() {
        XCTAssertEqual(BlockerKind.patternBlockedOn.displayName, "Pattern blocked on")
        XCTAssertEqual(BlockerKind.linearStuck.displayName, "Linear stuck")
        XCTAssertEqual(BlockerKind.other("ci_failure").displayName, "Ci failure")
        XCTAssertEqual(BlockerKind.other("multi_word_thing").displayName, "Multi word thing")
        XCTAssertEqual(BlockerKind.other("").displayName, "Unknown")
    }

    // MARK: - BlockerTargetKind enum

    func testBlockerTargetKind_linearIssueEquatable() {
        XCTAssertEqual(BlockerTargetKind.linearIssue, BlockerTargetKind.linearIssue)
    }

    func testBlockerTargetKind_otherFallback() {
        XCTAssertEqual(BlockerTargetKind.other("task"), BlockerTargetKind.other("task"))
        XCTAssertNotEqual(BlockerTargetKind.other("task"), BlockerTargetKind.linearIssue)
    }

    func testBlockerTargetKind_displayName() {
        XCTAssertEqual(BlockerTargetKind.linearIssue.displayName, "Linear")
        XCTAssertEqual(BlockerTargetKind.githubPR.displayName, "GitHub")
        XCTAssertEqual(BlockerTargetKind.other("task").displayName, "Task")
    }

    // MARK: - Blocker struct

    func testBlocker_memberwiseInit() {
        let blocker = Blocker(
            id: 1,
            targetKind: .linearIssue,
            targetRef: "LEAF-99",
            blockerKind: .linearStuck,
            excerpt: "Issue stuck for >5 days",
            startedAtMs: 1_700_000_000_000,
            resolvedAtMs: nil
        )
        XCTAssertEqual(blocker.id, 1)
        XCTAssertEqual(blocker.targetRef, "LEAF-99")
        XCTAssertNil(blocker.resolvedAtMs)
    }

    func testBlocker_resolvedRoundTrip() {
        let blocker = Blocker(
            id: 2,
            targetKind: .githubPR,
            targetRef: "owner/repo#42",
            blockerKind: .patternBlockedOn,
            excerpt: "Waiting for review",
            startedAtMs: 1_700_000_000_000,
            resolvedAtMs: 1_700_000_999_999
        )
        XCTAssertNotNil(blocker.resolvedAtMs)
        XCTAssertEqual(blocker.resolvedAtMs! - blocker.startedAtMs, 999999)
    }

    func testBlocker_sendable() {
        // Compile-time check via type signature.
        let _: any Sendable = Blocker(
            id: 3, targetKind: .linearIssue, targetRef: "X",
            blockerKind: .linearStuck, excerpt: "x",
            startedAtMs: 0, resolvedAtMs: nil
        )
    }

    func testBlocker_hashable() {
        let a = Blocker(
            id: 4, targetKind: .linearIssue, targetRef: "X",
            blockerKind: .linearStuck, excerpt: "x",
            startedAtMs: 0, resolvedAtMs: nil)
        let b = Blocker(
            id: 4, targetKind: .linearIssue, targetRef: "X",
            blockerKind: .linearStuck, excerpt: "x",
            startedAtMs: 0, resolvedAtMs: nil)
        let c = Blocker(
            id: 5, targetKind: .linearIssue, targetRef: "X",
            blockerKind: .linearStuck, excerpt: "x",
            startedAtMs: 0, resolvedAtMs: nil)
        XCTAssertEqual(Set([a, b, c]).count, 2)
    }
}
