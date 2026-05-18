// Packages/LeafCore/Tests/LeafCoreTests/ReviewActivityResultTests.swift
import XCTest

@testable import LeafCore

final class ReviewActivityResultTests: XCTestCase {
    func test_decode_emptyDict_returnsNil() {
        XCTAssertNil(ReviewActivityResult.decode([:]))
    }

    func test_decode_missingPeriod_returnsNil() {
        let dict: [String: Any] = [
            "reviews_submitted_count": 0,
            "review_comments_count": 0,
            "review_thread_resolved_count": 0,
            "by_repo": [Any](),
            "linked_prs": [Any](),
        ]
        XCTAssertNil(ReviewActivityResult.decode(dict))
    }

    func test_decode_minimalValidDict() {
        let dict: [String: Any] = [
            "period": "today",
            "from": "2026-05-17T00:00:00Z",
            "to": "2026-05-17T23:59:59Z",
            "reviews_submitted_count": 3,
            "review_comments_count": 5,
            "review_thread_resolved_count": 2,
            "by_repo": [Any](),
            "linked_prs": [Any](),
        ]
        let r = ReviewActivityResult.decode(dict)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.periodLabel, "today")
        XCTAssertEqual(r?.reviewsSubmittedCount, 3)
        XCTAssertEqual(r?.reviewCommentsCount, 5)
        XCTAssertEqual(r?.reviewThreadResolvedCount, 2)
        XCTAssertEqual(r?.byRepo.count, 0)
        XCTAssertEqual(r?.linkedPRs.count, 0)
    }

    func test_decode_byRepoEntries() {
        let dict: [String: Any] = [
            "period": "week",
            "from": "x", "to": "y",
            "reviews_submitted_count": 0,
            "review_comments_count": 0,
            "review_thread_resolved_count": 0,
            "by_repo": [
                ["repo": "gundemtech/leaf", "reviews": 2, "comments": 1, "threads": 0],
                ["repo": "gundemtech/leaf-docs", "reviews": 1, "comments": 0, "threads": 0],
            ] as [[String: Any]],
            "linked_prs": [Any](),
        ]
        let r = ReviewActivityResult.decode(dict)
        XCTAssertEqual(r?.byRepo.count, 2)
        XCTAssertEqual(r?.byRepo.first?.repo, "gundemtech/leaf")
        XCTAssertEqual(r?.byRepo.first?.reviews, 2)
        XCTAssertEqual(r?.byRepo.first?.comments, 1)
        XCTAssertEqual(r?.byRepo.first?.threads, 0)
    }

    func test_decode_linkedPRsWithLinearID() {
        let dict: [String: Any] = [
            "period": "week",
            "from": "x", "to": "y",
            "reviews_submitted_count": 0,
            "review_comments_count": 0,
            "review_thread_resolved_count": 0,
            "by_repo": [Any](),
            "linked_prs": [
                ["repo": "gundemtech/leaf", "pr_number": 142, "linked_linear_id": "LEAF-99"],
                ["repo": "gundemtech/leaf", "pr_number": 143, "linked_linear_id": NSNull()],
            ] as [[String: Any]],
        ]
        let r = ReviewActivityResult.decode(dict)
        XCTAssertEqual(r?.linkedPRs.count, 2)
        XCTAssertEqual(r?.linkedPRs.first?.repo, "gundemtech/leaf")
        XCTAssertEqual(r?.linkedPRs.first?.prNumber, 142)
        XCTAssertEqual(r?.linkedPRs.first?.linkedLinearID, "LEAF-99")
        XCTAssertNil(r?.linkedPRs[1].linkedLinearID)
    }

    func test_decode_malformedByRepoSkipped() {
        let dict: [String: Any] = [
            "period": "today",
            "from": "x", "to": "y",
            "reviews_submitted_count": 0,
            "review_comments_count": 0,
            "review_thread_resolved_count": 0,
            "by_repo": [
                ["repo": "ok-repo", "reviews": 1, "comments": 1, "threads": 1],
                ["repo": "missing-numbers"],  // malformed — should skip
            ] as [[String: Any]],
            "linked_prs": [Any](),
        ]
        let r = ReviewActivityResult.decode(dict)
        XCTAssertEqual(r?.byRepo.count, 1, "malformed entry should be skipped")
        XCTAssertEqual(r?.byRepo.first?.repo, "ok-repo")
    }

    func test_decode_malformedLinkedPRsSkipped() {
        let dict: [String: Any] = [
            "period": "today",
            "from": "x", "to": "y",
            "reviews_submitted_count": 0,
            "review_comments_count": 0,
            "review_thread_resolved_count": 0,
            "by_repo": [Any](),
            "linked_prs": [
                ["repo": "ok-repo", "pr_number": 1],
                ["repo": "missing-pr"],
            ] as [[String: Any]],
        ]
        let r = ReviewActivityResult.decode(dict)
        XCTAssertEqual(r?.linkedPRs.count, 1)
    }

    func test_decode_intCountsAsNSNumber() {
        let dict: [String: Any] = [
            "period": "today",
            "from": "x", "to": "y",
            "reviews_submitted_count": NSNumber(value: 7),
            "review_comments_count": NSNumber(value: 3),
            "review_thread_resolved_count": NSNumber(value: 1),
            "by_repo": [Any](),
            "linked_prs": [Any](),
        ]
        let r = ReviewActivityResult.decode(dict)
        XCTAssertEqual(r?.reviewsSubmittedCount, 7)
        XCTAssertEqual(r?.reviewCommentsCount, 3)
        XCTAssertEqual(r?.reviewThreadResolvedCount, 1)
    }

    func test_equatable() {
        let dict: [String: Any] = [
            "period": "today",
            "from": "x", "to": "y",
            "reviews_submitted_count": 1,
            "review_comments_count": 0,
            "review_thread_resolved_count": 0,
            "by_repo": [Any](),
            "linked_prs": [Any](),
        ]
        let a = ReviewActivityResult.decode(dict)
        let b = ReviewActivityResult.decode(dict)
        XCTAssertEqual(a, b)
    }

    func test_repoEntry_equatable() {
        let r1 = ReviewActivityResult.RepoEntry(repo: "a", reviews: 1, comments: 2, threads: 3)
        let r2 = ReviewActivityResult.RepoEntry(repo: "a", reviews: 1, comments: 2, threads: 3)
        XCTAssertEqual(r1, r2)
    }

    func test_linkedPREntry_hashableInSet() {
        let p1 = ReviewActivityResult.LinkedPREntry(repo: "r", prNumber: 1, linkedLinearID: nil)
        let p2 = ReviewActivityResult.LinkedPREntry(repo: "r", prNumber: 1, linkedLinearID: nil)
        let set: Set<ReviewActivityResult.LinkedPREntry> = [p1, p2]
        XCTAssertEqual(set.count, 1)
    }

    func test_decode_emptyLinkedPRs_noCrash() {
        let dict: [String: Any] = [
            "period": "today",
            "from": "x", "to": "y",
            "reviews_submitted_count": 0,
            "review_comments_count": 0,
            "review_thread_resolved_count": 0,
            "by_repo": [Any](),
            "linked_prs": [Any](),
        ]
        XCTAssertNotNil(ReviewActivityResult.decode(dict))
    }
}
