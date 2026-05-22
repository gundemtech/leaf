//
//  InboxFilteringTests.swift
//  Phase 8.9 (P9) — C-17: extracted InboxBlock.filteredItems logic now
//  unit-testable as a pure function over [InboxItem] inputs.
//

import XCTest

@testable import LeafCore

final class InboxFilteringTests: XCTestCase {
    // MARK: - Fixtures

    private func makeItem(
        id: String,
        kind: InboxKind,
        title: String,
        sourceMeta: String
    ) -> InboxItem {
        InboxItem(
            id: id,
            kind: kind,
            severity: .warn,
            title: title,
            sourceMeta: sourceMeta,
            sourceURL: nil,
            aggregatedCount: 1,
            createdAtMs: 0
        )
    }

    private lazy var fixtures: [InboxItem] = [
        makeItem(id: "1", kind: .reviewRequest, title: "Review track-8 polish", sourceMeta: "github · PR #42"),
        makeItem(id: "2", kind: .openQuestion, title: "Should we ship narrow fallback?", sourceMeta: "slack · #design"),
        makeItem(id: "3", kind: .mention, title: "Anton mentioned you", sourceMeta: "linear · LEAF-204"),
        makeItem(id: "4", kind: .reviewRequest, title: "Review meta-only filtering", sourceMeta: "github · PR #43"),
    ]

    // MARK: - Cases

    func testEmptyItemsEmptyQueryAll() {
        XCTAssertEqual(InboxFiltering.filtered(items: [], filter: .all, query: "").count, 0)
    }

    func testItemsEmptyQueryAll_preservesAll() {
        XCTAssertEqual(
            InboxFiltering.filtered(items: fixtures, filter: .all, query: "").map { $0.id },
            ["1", "2", "3", "4"]
        )
    }

    func testFilterReviews_onlyReviewKind() {
        XCTAssertEqual(
            InboxFiltering.filtered(items: fixtures, filter: .reviews, query: "").map { $0.id },
            ["1", "4"]
        )
    }

    func testFilterQuestions_onlyOpenQuestionKind() {
        XCTAssertEqual(
            InboxFiltering.filtered(items: fixtures, filter: .questions, query: "").map { $0.id },
            ["2"]
        )
    }

    func testFilterMentions_onlyMentionKind() {
        XCTAssertEqual(
            InboxFiltering.filtered(items: fixtures, filter: .mentions, query: "").map { $0.id },
            ["3"]
        )
    }

    func testQueryReview_caseInsensitiveTitleMatch() {
        XCTAssertEqual(
            InboxFiltering.filtered(items: fixtures, filter: .all, query: "review").map { $0.id },
            ["1", "4"]
        )
    }

    func testQueryUPPERCASE_caseInsensitive() {
        XCTAssertEqual(
            InboxFiltering.filtered(items: fixtures, filter: .all, query: "REVIEW").map { $0.id },
            ["1", "4"]
        )
    }

    func testQueryWithSurroundingWhitespace_trimmed() {
        XCTAssertEqual(
            InboxFiltering.filtered(items: fixtures, filter: .all, query: "  anton  ").map { $0.id },
            ["3"]
        )
    }

    func testQuerySourceMetaSubstringMatch() {
        XCTAssertEqual(
            InboxFiltering.filtered(items: fixtures, filter: .all, query: "LEAF-204").map { $0.id },
            ["3"]
        )
    }

    func testFilterAndQueryCombined_AND() {
        XCTAssertEqual(
            InboxFiltering.filtered(items: fixtures, filter: .reviews, query: "meta-only").map { $0.id },
            ["4"]
        )
    }
}

// MARK: - Track-9 T8: .alerts filter coverage
extension InboxFilteringTests {

    func testFilterAlerts_admitsBuildAndCIAndLiveMeeting_onlyThose() {
        let now = Int64(1_700_000_000_000)
        let items: [InboxItem] = [
            InboxItem(id: "1", kind: .buildFailed, severity: .warn, title: "Build failed", sourceMeta: "Xcode", sourceURL: nil, aggregatedCount: 1, createdAtMs: now),
            InboxItem(id: "2", kind: .ciFailed, severity: .danger, title: "CI red", sourceMeta: "GitHub", sourceURL: nil, aggregatedCount: 1, createdAtMs: now),
            InboxItem(id: "3", kind: .liveMeeting, severity: .muted, title: "In Zoom", sourceMeta: "Zoom", sourceURL: nil, aggregatedCount: 1, createdAtMs: now),
            InboxItem(id: "4", kind: .reviewRequest, severity: .warn, title: "Review", sourceMeta: "GH", sourceURL: nil, aggregatedCount: 1, createdAtMs: now),
            InboxItem(id: "5", kind: .openQuestion, severity: .warn, title: "Q", sourceMeta: "Slack", sourceURL: nil, aggregatedCount: 1, createdAtMs: now),
        ]

        let result = InboxFiltering.filtered(items: items, filter: .alerts, query: "")

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(Set(result.map { $0.id }), Set(["1", "2", "3"]))
    }
}

// MARK: - Track-10 T4: .actionable filter coverage
// See docs/superpowers/specs/2026-05-22-track-10-T4-needs-you.md §3.1 / §3.6.
extension InboxFilteringTests {

    /// 10-item mixed fixture: 7 kinds in the .actionable whitelist (one each)
    /// + 3 kinds from the 7-dropped set (sampled).
    private var actionableMixedFixtures: [InboxItem] {
        let now = Int64(1_700_000_000_000)
        return [
            // Admits whitelist (7) — one item per kind
            InboxItem(id: "a1", kind: .reviewRequest, severity: .warn, title: "Review PR #42", sourceMeta: "github · PR #42", sourceURL: nil, aggregatedCount: 1, createdAtMs: now),
            InboxItem(id: "a2", kind: .mention, severity: .warn, title: "Anton mentioned you", sourceMeta: "slack · #design", sourceURL: nil, aggregatedCount: 1, createdAtMs: now),
            InboxItem(id: "a3", kind: .openQuestion, severity: .warn, title: "Ship narrow fallback?", sourceMeta: "slack · #design", sourceURL: nil, aggregatedCount: 1, createdAtMs: now),
            InboxItem(id: "a4", kind: .blocker, severity: .danger, title: "Sasha input on relay rotation", sourceMeta: "linear · LEAF-187", sourceURL: nil, aggregatedCount: 1, createdAtMs: now),
            InboxItem(id: "a5", kind: .buildFailed, severity: .warn, title: "Build failed", sourceMeta: "Xcode", sourceURL: nil, aggregatedCount: 1, createdAtMs: now),
            InboxItem(id: "a6", kind: .ciFailed, severity: .danger, title: "CI red", sourceMeta: "github · checks", sourceURL: nil, aggregatedCount: 1, createdAtMs: now),
            InboxItem(id: "a7", kind: .liveMeeting, severity: .muted, title: "In Zoom", sourceMeta: "Zoom", sourceURL: nil, aggregatedCount: 1, createdAtMs: now),
            // Dropped (3 of 7 sampled) — visible only via .all chip
            InboxItem(id: "d1", kind: .commentOnMyWork, severity: .muted, title: "New comment", sourceMeta: "github · PR #41", sourceURL: nil, aggregatedCount: 1, createdAtMs: now),
            InboxItem(id: "d2", kind: .calUpcoming15min, severity: .muted, title: "Standup at 10:00", sourceMeta: "calendar", sourceURL: nil, aggregatedCount: 1, createdAtMs: now),
            InboxItem(id: "d3", kind: .slackDM, severity: .muted, title: "DM from PM", sourceMeta: "slack · DM", sourceURL: nil, aggregatedCount: 1, createdAtMs: now),
        ]
    }

    func testFilterActionable_admitsSevenKinds_dropsThree() {
        let result = InboxFiltering.filtered(
            items: actionableMixedFixtures, filter: .actionable, query: "")
        XCTAssertEqual(result.count, 7)
        XCTAssertEqual(Set(result.map { $0.id }), Set(["a1", "a2", "a3", "a4", "a5", "a6", "a7"]))
    }

    func testFilterActionable_withQuery_intersectsAdmitsAndQuery() {
        // Query "build" matches only a5 title ("Build failed") across the
        // 10-item fixture; the .actionable filter is permissive over a5
        // (it's in the 7-kind whitelist) so intersection = [a5].
        let result = InboxFiltering.filtered(
            items: actionableMixedFixtures, filter: .actionable, query: "build")
        XCTAssertEqual(result.map { $0.id }, ["a5"])
    }

    func testFilterActionable_allDropped_returnsEmpty() {
        let now = Int64(1_700_000_000_000)
        let droppedOnly: [InboxItem] = [
            InboxItem(id: "d1", kind: .commentOnMyWork, severity: .muted, title: "Comment", sourceMeta: "gh", sourceURL: nil, aggregatedCount: 1, createdAtMs: now),
            InboxItem(id: "d2", kind: .reminderDueToday, severity: .muted, title: "Reminder", sourceMeta: "rem", sourceURL: nil, aggregatedCount: 1, createdAtMs: now),
            InboxItem(id: "d3", kind: .mailUnreadBucket, severity: .muted, title: "5 unread", sourceMeta: "mail", sourceURL: nil, aggregatedCount: 1, createdAtMs: now),
        ]
        let result = InboxFiltering.filtered(items: droppedOnly, filter: .actionable, query: "")
        XCTAssertEqual(result.count, 0)
    }
}
