// Phase 4.7.B-17 — `ReviewActivityInsights.reviewActivity` (testable backing
// for the `get_review_activity` MCP tool).
//
// The LeafMCP target builds under Xcode (not under `swift test`), so the
// `GetReviewActivityTool` tool-struct in `LeafMCP/Tools/` is tested through its
// LeafCore helper. Here — all 3 planned cases:
//
//   - testExecute_NoData_ReturnsZeros
//   - testExecute_AggregatesByEventKindAndRepo
//   - testExecute_LinkedPRs_DeduplicatedAndFiltered

import XCTest
import GRDB
@testable import LeafCore

final class ReviewActivityTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-review-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func makeReviewSubmittedEvent(
        repo: String,
        prNumber: Int?,
        linkedLinearID: String? = nil,
        atMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": "gh_pr_review_submitted",
            "repo": repo,
            "title": "",
            "number": prNumber.map(String.init) ?? "",
            "sha": "",
            "branch": ""
        ]
        if let linked = linkedLinearID {
            payload["linked_linear_id"] = linked
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(atMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: payload
        )
    }

    private func makeReviewCommentEvent(
        repo: String,
        prNumber: Int?,
        linkedLinearID: String? = nil,
        atMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": "gh_pr_review_comment_authored",
            "repo": repo,
            "title": "",
            "number": prNumber.map(String.init) ?? "",
            "sha": "",
            "branch": "",
            "action": "created"
        ]
        if let linked = linkedLinearID {
            payload["linked_linear_id"] = linked
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(atMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: payload
        )
    }

    private func makePROpenedEvent(
        repo: String,
        prNumber: Int,
        linkedLinearID: String? = nil,
        atMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": "gh_pr_opened",
            "repo": repo,
            "title": "",
            "number": String(prNumber),
            "sha": "",
            "branch": ""
        ]
        if let linked = linkedLinearID {
            payload["linked_linear_id"] = linked
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(atMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: payload
        )
    }

    /// Compute event timestamp inside today's window (mirrors WorkloadPulseTests).
    private func todayEventMs(now: Date = Date(), offsetSeconds: TimeInterval = 60 * 60) -> Int64 {
        let todayStart = Calendar.current.startOfDay(for: now)
        return Int64(todayStart.addingTimeInterval(offsetSeconds).timeIntervalSince1970 * 1000)
    }

    // MARK: - testExecute_NoData_ReturnsZeros

    /// A fresh (just-created) DB → counts=0, by_repo=[], linked_prs=[].
    /// Top-level keys are present — the shape is preserved even with empty data.
    func testExecute_NoData_ReturnsZeros() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let payload = try ReviewActivityInsights.reviewActivity(database: db, period: .today)

        XCTAssertEqual(payload["period"] as? String, "today")
        XCTAssertEqual(payload["reviews_submitted_count"] as? Int, 0)
        XCTAssertEqual(payload["review_comments_count"] as? Int, 0)
        XCTAssertEqual(payload["review_thread_resolved_count"] as? Int, 0,
                       "Track C event_kind is not emitted yet — count must be 0")

        let byRepo = try XCTUnwrap(payload["by_repo"] as? [[String: Any]])
        XCTAssertTrue(byRepo.isEmpty, "by_repo must be an empty array")

        let linkedPRs = try XCTUnwrap(payload["linked_prs"] as? [[String: Any]])
        XCTAssertTrue(linkedPRs.isEmpty, "linked_prs must be an empty array")

        XCTAssertNotNil(payload["from"] as? String)
        XCTAssertNotNil(payload["to"] as? String)
    }

    // MARK: - testExecute_AggregatesByEventKindAndRepo

    /// Seed 4 review_submitted + 3 pr_review_comment_authored across 2 repos →
    /// reviews_submitted_count=4, review_comments_count=3, by_repo aggregates
    /// correct, with DESC ordering by (reviews + comments).
    func testExecute_AggregatesByEventKindAndRepo() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let now = Date()
        let baseMs = todayEventMs(now: now)

        // repo-a: 3 reviews + 2 comments = 5 total
        // repo-b: 1 review  + 1 comment  = 2 total
        let events: [RawEvent] = [
            makeReviewSubmittedEvent(repo: "owner/repo-a", prNumber: 1, atMs: baseMs),
            makeReviewSubmittedEvent(repo: "owner/repo-a", prNumber: 2, atMs: baseMs + 100),
            makeReviewSubmittedEvent(repo: "owner/repo-a", prNumber: 3, atMs: baseMs + 200),
            makeReviewSubmittedEvent(repo: "owner/repo-b", prNumber: 4, atMs: baseMs + 300),
            makeReviewCommentEvent(repo: "owner/repo-a", prNumber: 1, atMs: baseMs + 400),
            makeReviewCommentEvent(repo: "owner/repo-a", prNumber: 2, atMs: baseMs + 500),
            makeReviewCommentEvent(repo: "owner/repo-b", prNumber: 4, atMs: baseMs + 600)
        ]
        try db.write(events)

        let payload = try ReviewActivityInsights.reviewActivity(
            database: db, period: .today, now: now
        )

        XCTAssertEqual(payload["reviews_submitted_count"] as? Int, 4)
        XCTAssertEqual(payload["review_comments_count"] as? Int, 3)
        XCTAssertEqual(payload["review_thread_resolved_count"] as? Int, 0)

        let byRepo = try XCTUnwrap(payload["by_repo"] as? [[String: Any]])
        XCTAssertEqual(byRepo.count, 2)

        // DESC ordering — repo-a (5 total) first, repo-b (2 total) second.
        XCTAssertEqual(byRepo[0]["repo"] as? String, "owner/repo-a")
        XCTAssertEqual(byRepo[0]["reviews"] as? Int, 3)
        XCTAssertEqual(byRepo[0]["comments"] as? Int, 2)
        XCTAssertEqual(byRepo[1]["repo"] as? String, "owner/repo-b")
        XCTAssertEqual(byRepo[1]["reviews"] as? Int, 1)
        XCTAssertEqual(byRepo[1]["comments"] as? Int, 1)

        // Optional repo filter — narrow to repo-b only.
        let filtered = try ReviewActivityInsights.reviewActivity(
            database: db, period: .today, repo: "owner/repo-b", now: now
        )
        XCTAssertEqual(filtered["reviews_submitted_count"] as? Int, 1)
        XCTAssertEqual(filtered["review_comments_count"] as? Int, 1)
        let filteredByRepo = try XCTUnwrap(filtered["by_repo"] as? [[String: Any]])
        XCTAssertEqual(filteredByRepo.count, 1)
        XCTAssertEqual(filteredByRepo[0]["repo"] as? String, "owner/repo-b")
    }

    // MARK: - testExecute_LinkedPRs_DeduplicatedAndFiltered

    /// Seed events with linked_linear_id (review + pr_opened) on the same (repo, pr_number,
    /// linked_id) → linked_prs deduplicated. Events without linked_linear_id or
    /// without pr_number are dropped.
    func testExecute_LinkedPRs_DeduplicatedAndFiltered() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let now = Date()
        let baseMs = todayEventMs(now: now)

        let events: [RawEvent] = [
            // (repo-a, PR#42, LEAF-100) — duplicated across 3 events with different
            // event_kinds (review_submitted + pr_review_comment + pr_opened) →
            // SELECT DISTINCT must collapse them into ONE linked_prs row.
            makeReviewSubmittedEvent(
                repo: "owner/repo-a", prNumber: 42, linkedLinearID: "LEAF-100", atMs: baseMs
            ),
            makeReviewCommentEvent(
                repo: "owner/repo-a", prNumber: 42, linkedLinearID: "LEAF-100", atMs: baseMs + 100
            ),
            makePROpenedEvent(
                repo: "owner/repo-a", prNumber: 42, linkedLinearID: "LEAF-100", atMs: baseMs + 200
            ),
            // (repo-b, PR#7, LEAF-200) — a separate pair.
            makePROpenedEvent(
                repo: "owner/repo-b", prNumber: 7, linkedLinearID: "LEAF-200", atMs: baseMs + 300
            ),
            // No linked_linear_id → dropped from linked_prs (but the review counts still add up).
            makeReviewSubmittedEvent(
                repo: "owner/repo-a", prNumber: 50, linkedLinearID: nil, atMs: baseMs + 400
            ),
            // No pr_number (commit_pushed-style review without PR context — synthetic edge) → skip.
            makeReviewSubmittedEvent(
                repo: "owner/repo-a", prNumber: nil, linkedLinearID: "LEAF-300", atMs: baseMs + 500
            )
        ]
        try db.write(events)

        let payload = try ReviewActivityInsights.reviewActivity(
            database: db, period: .today, now: now
        )

        let linkedPRs = try XCTUnwrap(payload["linked_prs"] as? [[String: Any]])
        XCTAssertEqual(linkedPRs.count, 2,
                       "DISTINCT(repo, pr_number, linked_linear_id) → 3 dup events on (repo-a, 42, LEAF-100) collapse into 1; (repo-b, 7, LEAF-200) is a separate row; events without linked_id or without pr_number are dropped")

        // Sorted ASC by (repo, pr_number) — determinism.
        XCTAssertEqual(linkedPRs[0]["repo"] as? String, "owner/repo-a")
        XCTAssertEqual(linkedPRs[0]["pr_number"] as? Int, 42)
        XCTAssertEqual(linkedPRs[0]["linked_linear_id"] as? String, "LEAF-100")

        XCTAssertEqual(linkedPRs[1]["repo"] as? String, "owner/repo-b")
        XCTAssertEqual(linkedPRs[1]["pr_number"] as? Int, 7)
        XCTAssertEqual(linkedPRs[1]["linked_linear_id"] as? String, "LEAF-200")

        // Sanity — review counts include ALL review-flavored events regardless
        // of linked_id presence.  Seeded review events (event_kind=review_submitted):
        // (repo-a, 42, LEAF-100), (repo-a, 50, no link), (repo-a, no pr_number, LEAF-300) → 3.
        // pr_opened events (#2, #3) are NOT counted as review_submitted.
        XCTAssertEqual(payload["reviews_submitted_count"] as? Int, 3,
                       "3 review_submitted events seeded — pr_opened/comment events are not in this count")
        XCTAssertEqual(payload["review_comments_count"] as? Int, 1)
    }
}
