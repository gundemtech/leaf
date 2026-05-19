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
