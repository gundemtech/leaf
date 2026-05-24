//
//  StandupSnapshotTests.swift
//  Track-10 T8 — locks the bundled `StandupSnapshot` value type (recap +
//  eod) consumed by Home Zone-5 RecapBlock / EodBlock. `isEmpty` is
//  load-bearing for view-tier empty-state routing (precedent: T7
//  CurrentTaskSession + T5 SinceLastActiveItem). No Codable per T7
//  F-CTO-A — nested InboxItem / Blocker / TaskIdentity /
//  WhereStoppedSnapshot are not Codable and Codable round-trip was an
//  over-specification in the planning doc.
//

import XCTest

@testable import LeafCore

final class StandupSnapshotTests: XCTestCase {

    // MARK: - StandupRecap.isEmpty

    func testStandupRecap_isEmpty_whenAllZeroOrNil() {
        let recap = StandupRecap(
            yesterdayCommitsCount: 0,
            yesterdayClosedLinearKeys: [],
            yesterdayReviewedPRsCount: 0,
            todayContinuing: nil,
            waitingItems: [],
            openBlockers: []
        )
        XCTAssertTrue(recap.isEmpty)
    }

    func testStandupRecap_notEmpty_whenCommitsCountPositive() {
        let recap = StandupRecap(
            yesterdayCommitsCount: 3,
            yesterdayClosedLinearKeys: [],
            yesterdayReviewedPRsCount: 0,
            todayContinuing: nil,
            waitingItems: [],
            openBlockers: []
        )
        XCTAssertFalse(recap.isEmpty)
    }

    func testStandupRecap_notEmpty_whenLinearKeysPresent() {
        let recap = StandupRecap(
            yesterdayCommitsCount: 0,
            yesterdayClosedLinearKeys: ["GUN-204"],
            yesterdayReviewedPRsCount: 0,
            todayContinuing: nil,
            waitingItems: [],
            openBlockers: []
        )
        XCTAssertFalse(recap.isEmpty)
    }

    func testStandupRecap_notEmpty_whenReviewedPRsPositive() {
        let recap = StandupRecap(
            yesterdayCommitsCount: 0,
            yesterdayClosedLinearKeys: [],
            yesterdayReviewedPRsCount: 2,
            todayContinuing: nil,
            waitingItems: [],
            openBlockers: []
        )
        XCTAssertFalse(recap.isEmpty)
    }

    func testStandupRecap_notEmpty_whenWaitingItemsPresent() {
        let item = InboxItem(
            id: "i1", kind: .reviewRequest, severity: .warn,
            title: "PR #141", sourceMeta: "owner/repo · #141",
            sourceURL: nil, aggregatedCount: 1, createdAtMs: 0
        )
        let recap = StandupRecap(
            yesterdayCommitsCount: 0,
            yesterdayClosedLinearKeys: [],
            yesterdayReviewedPRsCount: 0,
            todayContinuing: nil,
            waitingItems: [item],
            openBlockers: []
        )
        XCTAssertFalse(recap.isEmpty)
    }

    func testStandupRecap_notEmpty_whenOpenBlockersPresent() {
        let blocker = Blocker(
            id: 1, targetKind: .linearIssue, targetRef: "GUN-50",
            blockerKind: .patternBlockedOn, excerpt: "waiting on Sasha",
            startedAtMs: 0, resolvedAtMs: nil
        )
        let recap = StandupRecap(
            yesterdayCommitsCount: 0,
            yesterdayClosedLinearKeys: [],
            yesterdayReviewedPRsCount: 0,
            todayContinuing: nil,
            waitingItems: [],
            openBlockers: [blocker]
        )
        XCTAssertFalse(recap.isEmpty)
    }

    /// `todayContinuing` alone does NOT defeat isEmpty — "Today: continuing X"
    /// without any backing yesterday activity reads as broken/empty standup.
    func testStandupRecap_emptyEvenWhenTodayContinuingPopulated() {
        let recap = StandupRecap(
            yesterdayCommitsCount: 0,
            yesterdayClosedLinearKeys: [],
            yesterdayReviewedPRsCount: 0,
            todayContinuing: TaskIdentity(linearID: "GUN-208"),
            waitingItems: [],
            openBlockers: []
        )
        XCTAssertTrue(recap.isEmpty)
    }

    // MARK: - StandupEod.isEmpty / hasCleanBreak

    func testStandupEod_isEmpty_whenAllZeroOrNil() {
        let eod = StandupEod(
            todayCommitsCount: 0,
            todayClosedLinearKeys: [],
            todayReviewedPRsCount: 0,
            tomorrowResume: nil,
            carryWaitingItems: [],
            carryOpenBlockers: []
        )
        XCTAssertTrue(eod.isEmpty)
    }

    func testStandupEod_notEmpty_whenCommitsCountPositive() {
        let eod = StandupEod(
            todayCommitsCount: 5,
            todayClosedLinearKeys: [],
            todayReviewedPRsCount: 0,
            tomorrowResume: nil,
            carryWaitingItems: [],
            carryOpenBlockers: []
        )
        XCTAssertFalse(eod.isEmpty)
    }

    func testStandupEod_notEmpty_whenTomorrowResumePresent() {
        let ws = WhereStoppedSnapshot(
            id: 1, generatedAtMs: 0, anchorEventId: nil,
            excerpt: "stopped in InsightsReader.refresh()",
            wipSignals: ["foo"]
        )
        let eod = StandupEod(
            todayCommitsCount: 0,
            todayClosedLinearKeys: [],
            todayReviewedPRsCount: 0,
            tomorrowResume: ws,
            carryWaitingItems: [],
            carryOpenBlockers: []
        )
        XCTAssertFalse(eod.isEmpty)
    }

    /// `hasCleanBreak == true` iff both carry arrays empty (regardless of
    /// other today-* counts). Block view uses this together with isEmpty
    /// to decide whether to render the "Clean break" line.
    func testStandupEod_hasCleanBreak_whenNoCarries() {
        let eod = StandupEod(
            todayCommitsCount: 3,
            todayClosedLinearKeys: ["GUN-50"],
            todayReviewedPRsCount: 0,
            tomorrowResume: nil,
            carryWaitingItems: [],
            carryOpenBlockers: []
        )
        XCTAssertTrue(eod.hasCleanBreak)
    }

    func testStandupEod_noCleanBreak_whenCarryWaitingItemsPresent() {
        let item = InboxItem(
            id: "i1", kind: .reviewRequest, severity: .warn,
            title: "PR #141", sourceMeta: "owner/repo · #141",
            sourceURL: nil, aggregatedCount: 1, createdAtMs: 0
        )
        let eod = StandupEod(
            todayCommitsCount: 0,
            todayClosedLinearKeys: [],
            todayReviewedPRsCount: 0,
            tomorrowResume: nil,
            carryWaitingItems: [item],
            carryOpenBlockers: []
        )
        XCTAssertFalse(eod.hasCleanBreak)
    }

    func testStandupEod_noCleanBreak_whenCarryBlockersPresent() {
        let blocker = Blocker(
            id: 1, targetKind: .linearIssue, targetRef: "GUN-50",
            blockerKind: .patternBlockedOn, excerpt: "waiting on Sasha",
            startedAtMs: 0, resolvedAtMs: nil
        )
        let eod = StandupEod(
            todayCommitsCount: 0,
            todayClosedLinearKeys: [],
            todayReviewedPRsCount: 0,
            tomorrowResume: nil,
            carryWaitingItems: [],
            carryOpenBlockers: [blocker]
        )
        XCTAssertFalse(eod.hasCleanBreak)
    }

    // MARK: - StandupSnapshot wrapper

    func testStandupSnapshot_storesBothChildren() {
        let recap = StandupRecap(
            yesterdayCommitsCount: 1,
            yesterdayClosedLinearKeys: ["GUN-1"],
            yesterdayReviewedPRsCount: 0,
            todayContinuing: nil,
            waitingItems: [],
            openBlockers: []
        )
        let eod = StandupEod(
            todayCommitsCount: 2,
            todayClosedLinearKeys: ["GUN-2"],
            todayReviewedPRsCount: 0,
            tomorrowResume: nil,
            carryWaitingItems: [],
            carryOpenBlockers: []
        )
        let snapshot = StandupSnapshot(recap: recap, eod: eod)
        XCTAssertEqual(snapshot.recap?.yesterdayClosedLinearKeys, ["GUN-1"])
        XCTAssertEqual(snapshot.eod?.todayClosedLinearKeys, ["GUN-2"])
    }

    func testStandupSnapshot_acceptsNilChildren() {
        let snapshot = StandupSnapshot(recap: nil, eod: nil)
        XCTAssertNil(snapshot.recap)
        XCTAssertNil(snapshot.eod)
    }

    // MARK: - Equatable + Hashable contract

    func testStandupRecap_equatable_sameInputsEqual() {
        let a = StandupRecap(
            yesterdayCommitsCount: 1,
            yesterdayClosedLinearKeys: ["GUN-1"],
            yesterdayReviewedPRsCount: 0,
            todayContinuing: nil,
            waitingItems: [],
            openBlockers: []
        )
        let b = StandupRecap(
            yesterdayCommitsCount: 1,
            yesterdayClosedLinearKeys: ["GUN-1"],
            yesterdayReviewedPRsCount: 0,
            todayContinuing: nil,
            waitingItems: [],
            openBlockers: []
        )
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testStandupSnapshot_equatable_sameInputsEqual() {
        let snapshotA = StandupSnapshot(recap: nil, eod: nil)
        let snapshotB = StandupSnapshot(recap: nil, eod: nil)
        XCTAssertEqual(snapshotA, snapshotB)
        XCTAssertEqual(snapshotA.hashValue, snapshotB.hashValue)
    }
}
