//
//  StandupComposerTests.swift
//  Track-10 T8 — pure-function row composition for the Home Zone-5 standup
//  helper (RECAP morning brief + EOD end-of-day). Precedent:
//  YoureOnRowComposerTests / TeamNRowComposerTests. View body ships
//  untested (no SwiftUI snapshot infra); this suite locks the contract.
//

import Foundation
import XCTest

@testable import LeafCore

final class StandupComposerTests: XCTestCase {

    // MARK: - Fixture helpers

    private let now = Date(timeIntervalSince1970: 1_716_454_680)  // 2024-05-23 08:58 UTC
    private var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1000) }

    private func feedItem(
        ts: Int64,
        source: SinceSource,
        eventKind: String,
        actorIsMe: Bool = true,
        targetRef: String? = nil,
        targetTitle: String? = nil
    ) -> ActivityFeedItem {
        ActivityFeedItem(
            ts: ts, source: source, eventKind: eventKind,
            actorDisplay: actorIsMe ? "you" : "@teammate", actorIsMe: actorIsMe,
            targetTitle: targetTitle, targetRef: targetRef,
            repoHint: nil, sourceURL: nil
        )
    }

    private func inboxItem(
        id: String,
        severity: InboxSeverity = .warn,
        kind: InboxKind = .reviewRequest,
        ageHours: Double,
        title: String = "PR #141",
        sourceMeta: String = "owner/repo · #141"
    ) -> InboxItem {
        let createdMs = nowMs - Int64(ageHours * 60 * 60 * 1000)
        return InboxItem(
            id: id, kind: kind, severity: severity, title: title,
            sourceMeta: sourceMeta, sourceURL: nil,
            aggregatedCount: 1, createdAtMs: createdMs
        )
    }

    private func blocker(
        id: Int64 = 1,
        excerpt: String = "Sasha input on relay rotation API shape",
        targetRef: String = "GUN-50"
    ) -> Blocker {
        Blocker(
            id: id, targetKind: .linearIssue, targetRef: targetRef,
            blockerKind: .patternBlockedOn, excerpt: excerpt,
            startedAtMs: 0, resolvedAtMs: nil
        )
    }

    // MARK: - extractCompletedLinearKeys

    func testExtractCompletedLinearKeys_filtersToCompletedActorIsMeWithRef() {
        let feed: [ActivityFeedItem] = [
            feedItem(
                ts: nowMs - 1000, source: .linear,
                eventKind: LinearActivityKinds.statusTransitionCompletedKind,
                targetRef: "GUN-204"),
            // not actorIsMe — teammate's completion
            feedItem(
                ts: nowMs - 2000, source: .linear,
                eventKind: LinearActivityKinds.statusTransitionCompletedKind,
                actorIsMe: false, targetRef: "GUN-99"),
            // wrong kind (started, not completed)
            feedItem(
                ts: nowMs - 3000, source: .linear,
                eventKind: LinearActivityKinds.statusTransitionStartedKind,
                targetRef: "GUN-300"),
            // nil ref — must be dropped
            feedItem(
                ts: nowMs - 4000, source: .linear,
                eventKind: LinearActivityKinds.statusTransitionCompletedKind,
                targetRef: nil),
            feedItem(
                ts: nowMs - 5000, source: .linear,
                eventKind: LinearActivityKinds.statusTransitionCompletedKind,
                targetRef: "GUN-187"),
        ]
        XCTAssertEqual(
            StandupComposer.extractCompletedLinearKeys(feed),
            ["GUN-204", "GUN-187"]
        )
    }

    func testExtractCompletedLinearKeys_emptyFeed() {
        XCTAssertEqual(StandupComposer.extractCompletedLinearKeys([]), [])
    }

    /// F-CTO-T8-B — sort by ts desc FIRST, then dedupe (first-seen retention)
    /// so re-closed issues keep most-recent timestamp ordering.
    func testExtractCompletedLinearKeys_dedupePreservesMostRecent() {
        let feed: [ActivityFeedItem] = [
            // Older completion of GUN-204
            feedItem(
                ts: nowMs - 5000, source: .linear,
                eventKind: LinearActivityKinds.statusTransitionCompletedKind,
                targetRef: "GUN-204"),
            // A more-recent completion of GUN-100
            feedItem(
                ts: nowMs - 1000, source: .linear,
                eventKind: LinearActivityKinds.statusTransitionCompletedKind,
                targetRef: "GUN-100"),
            // The most-recent re-completion of GUN-204
            feedItem(
                ts: nowMs - 500, source: .linear,
                eventKind: LinearActivityKinds.statusTransitionCompletedKind,
                targetRef: "GUN-204"),
        ]
        // Expected order: GUN-204 (most recent re-completion), GUN-100.
        XCTAssertEqual(
            StandupComposer.extractCompletedLinearKeys(feed),
            ["GUN-204", "GUN-100"]
        )
    }

    func testExtractCompletedLinearKeys_capsAtCollectionCap5() {
        let feed: [ActivityFeedItem] = (0..<10).map { i in
            feedItem(
                ts: nowMs - Int64(i * 1000),
                source: .linear,
                eventKind: LinearActivityKinds.statusTransitionCompletedKind,
                targetRef: "GUN-\(100 + i)")
        }
        let keys = StandupComposer.extractCompletedLinearKeys(feed)
        XCTAssertEqual(keys.count, StandupComposer.issueKeysCollectionCap)
        XCTAssertEqual(keys.first, "GUN-100")
        XCTAssertEqual(keys.last, "GUN-104")
    }

    // MARK: - countReviewedPRs

    func testCountReviewedPRs_onlyAuthoredReviewsByMe() {
        let feed: [ActivityFeedItem] = [
            feedItem(
                ts: nowMs - 1, source: .github,
                eventKind: "gh_pr_review_authored", actorIsMe: true,
                targetRef: "#141"),
            feedItem(
                ts: nowMs - 2, source: .github,
                eventKind: "gh_pr_review_authored", actorIsMe: true,
                targetRef: "#142"),
            // requested-review-on-me ≠ I reviewed
            feedItem(
                ts: nowMs - 3, source: .github,
                eventKind: "gh_pr_review_requested", actorIsMe: true,
                targetRef: "#150"),
            // teammate review
            feedItem(
                ts: nowMs - 4, source: .github,
                eventKind: "gh_pr_review_authored", actorIsMe: false,
                targetRef: "#143"),
            // unrelated source
            feedItem(
                ts: nowMs - 5, source: .linear,
                eventKind: "gh_pr_review_authored", actorIsMe: true,
                targetRef: "X"),
        ]
        XCTAssertEqual(StandupComposer.countReviewedPRs(feed), 2)
    }

    func testCountReviewedPRs_empty() {
        XCTAssertEqual(StandupComposer.countReviewedPRs([]), 0)
    }

    // MARK: - staleWaitingItems

    func testStaleWaitingItems_filtersToOlderThanCutoff_capsAt3() {
        let items: [InboxItem] = [
            inboxItem(id: "fresh", ageHours: 1),
            inboxItem(id: "stale-25h", ageHours: 25),
            inboxItem(id: "stale-26h", ageHours: 26),
            inboxItem(id: "stale-27h-danger", severity: .danger, ageHours: 27),
            inboxItem(id: "stale-100h", ageHours: 100),
        ]
        let filtered = StandupComposer.staleWaitingItems(items, now: now)
        XCTAssertEqual(filtered.count, StandupComposer.waitingCap)
        // sortRank: danger=0, warn=1, muted=2 — danger first.
        XCTAssertEqual(filtered.first?.id, "stale-27h-danger")
        // Within same severity, oldest first.
        let warnIDs = filtered.dropFirst().map(\.id)
        XCTAssertEqual(Array(warnIDs), ["stale-100h", "stale-26h"])
    }

    /// F-CTO-T8 boundary — 24h0m1ms = included, 23h59m59s = excluded.
    func testStaleWaitingItems_24hBoundary() {
        let cutoffMs: Int64 = StandupComposer.stalenessCutoffMs
        let justOver = InboxItem(
            id: "over", kind: .reviewRequest, severity: .warn,
            title: "PR over", sourceMeta: "",
            sourceURL: nil, aggregatedCount: 1,
            createdAtMs: nowMs - cutoffMs - 1
        )
        let justUnder = InboxItem(
            id: "under", kind: .reviewRequest, severity: .warn,
            title: "PR under", sourceMeta: "",
            sourceURL: nil, aggregatedCount: 1,
            createdAtMs: nowMs - cutoffMs + 1_000
        )
        let filtered = StandupComposer.staleWaitingItems([justOver, justUnder], now: now)
        XCTAssertEqual(filtered.map(\.id), ["over"])
    }

    // MARK: - renderLinearKeysClause

    func testRenderLinearKeysClause_emptyReturnsNil() {
        XCTAssertNil(StandupComposer.renderLinearKeysClause([]))
    }

    func testRenderLinearKeysClause_one() {
        XCTAssertEqual(
            StandupComposer.renderLinearKeysClause(["GUN-204"]),
            "closed GUN-204"
        )
    }

    func testRenderLinearKeysClause_two() {
        XCTAssertEqual(
            StandupComposer.renderLinearKeysClause(["GUN-204", "GUN-187"]),
            "closed GUN-204, GUN-187"
        )
    }

    /// F-CTO-T8-N — collection cap=5, render cap=3; overflow "+N more".
    func testRenderLinearKeysClause_overflowSuffix() {
        XCTAssertEqual(
            StandupComposer.renderLinearKeysClause(
                ["GUN-204", "GUN-187", "GUN-103", "GUN-92", "GUN-88"]
            ),
            "closed GUN-204, GUN-187, GUN-103 +2 more"
        )
    }

    func testRenderLinearKeysClause_exactlyRenderCap_noSuffix() {
        XCTAssertEqual(
            StandupComposer.renderLinearKeysClause(
                ["GUN-204", "GUN-187", "GUN-103"]
            ),
            "closed GUN-204, GUN-187, GUN-103"
        )
    }

    // MARK: - formatItemAge

    func testFormatItemAge_under60s_returnsNow() {
        let createdMs = nowMs - 30 * 1000
        XCTAssertEqual(StandupComposer.formatItemAge(createdMs, now: now), "now")
    }

    func testFormatItemAge_minutes() {
        let createdMs = nowMs - 30 * 60 * 1000
        XCTAssertEqual(StandupComposer.formatItemAge(createdMs, now: now), "30m")
    }

    func testFormatItemAge_hours() {
        let createdMs = nowMs - 6 * 60 * 60 * 1000
        XCTAssertEqual(StandupComposer.formatItemAge(createdMs, now: now), "6h")
    }

    func testFormatItemAge_oneDay() {
        let createdMs = nowMs - 26 * 60 * 60 * 1000
        XCTAssertEqual(StandupComposer.formatItemAge(createdMs, now: now), "1d")
    }

    func testFormatItemAge_multipleDays() {
        let createdMs = nowMs - 48 * 60 * 60 * 1000
        XCTAssertEqual(StandupComposer.formatItemAge(createdMs, now: now), "2d")
    }

    // MARK: - renderWaitingBullet

    func testRenderWaitingBullet_composesTitleAndAge() {
        let item = inboxItem(id: "i", ageHours: 48, title: "PR #141 awaiting your review")
        XCTAssertEqual(
            StandupComposer.renderWaitingBullet(item, now: now),
            "PR #141 awaiting your review (2d)"
        )
    }

    // MARK: - renderBlockerBullet

    func testRenderBlockerBullet_excerptOnly() {
        let b = blocker(excerpt: "Sasha input on relay rotation API shape")
        XCTAssertEqual(
            StandupComposer.renderBlockerBullet(b),
            "Sasha input on relay rotation API shape"
        )
    }

    // MARK: - compose(...)

    func testCompose_fullBundle_returnsBothPopulated() {
        let yesterday: [ActivityFeedItem] = [
            feedItem(
                ts: nowMs - 1000, source: .linear,
                eventKind: LinearActivityKinds.statusTransitionCompletedKind,
                targetRef: "GUN-204"),
            feedItem(
                ts: nowMs - 2000, source: .github,
                eventKind: "gh_pr_review_authored", targetRef: "#141"),
        ]
        let today: [ActivityFeedItem] = [
            feedItem(
                ts: nowMs - 100, source: .linear,
                eventKind: LinearActivityKinds.statusTransitionCompletedKind,
                targetRef: "GUN-300"),
        ]
        let yesterdayMetrics = TodayMetrics(
            focusedMin: 0, aiRatio: 0, sessionsCount: 0,
            switchCount: 0, commitsCount: 3, surfacePills: []
        )
        let todayMetrics = TodayMetrics(
            focusedMin: 0, aiRatio: 0, sessionsCount: 0,
            switchCount: 0, commitsCount: 5, surfacePills: []
        )
        let waitingItem = inboxItem(id: "w1", ageHours: 30)
        let blockers = [blocker()]
        let snapshot = StandupComposer.compose(
            yesterdayActivity: yesterday,
            todayActivity: today,
            yesterdayMetrics: yesterdayMetrics,
            todayMetrics: todayMetrics,
            actionableItems: [waitingItem],
            openBlockers: blockers,
            currentTask: TaskIdentity(linearID: "GUN-208"),
            latestStop: nil,
            now: now
        )
        XCTAssertNotNil(snapshot.recap)
        XCTAssertEqual(snapshot.recap?.yesterdayCommitsCount, 3)
        XCTAssertEqual(snapshot.recap?.yesterdayClosedLinearKeys, ["GUN-204"])
        XCTAssertEqual(snapshot.recap?.yesterdayReviewedPRsCount, 1)
        XCTAssertEqual(snapshot.recap?.todayContinuing?.linearID, "GUN-208")
        XCTAssertEqual(snapshot.recap?.waitingItems.map(\.id), ["w1"])
        XCTAssertEqual(snapshot.recap?.openBlockers.count, 1)

        XCTAssertNotNil(snapshot.eod)
        XCTAssertEqual(snapshot.eod?.todayCommitsCount, 5)
        XCTAssertEqual(snapshot.eod?.todayClosedLinearKeys, ["GUN-300"])
        XCTAssertEqual(snapshot.eod?.todayReviewedPRsCount, 0)
        XCTAssertEqual(snapshot.eod?.carryWaitingItems.map(\.id), ["w1"])
    }

    func testCompose_allZeroInputs_returnsNilChildren() {
        let snapshot = StandupComposer.compose(
            yesterdayActivity: [],
            todayActivity: [],
            yesterdayMetrics: .empty,
            todayMetrics: .empty,
            actionableItems: [],
            openBlockers: [],
            currentTask: nil,
            latestStop: nil,
            now: now
        )
        XCTAssertNil(snapshot.recap)
        XCTAssertNil(snapshot.eod)
    }
}
