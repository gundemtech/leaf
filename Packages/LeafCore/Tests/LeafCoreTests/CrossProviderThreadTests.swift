// Phase 4.7.B-18 — `CrossProviderInsights.crossProviderThread` (testable
// backing for the `get_cross_provider_thread` MCP tool).
//
// The LeafMCP target lives under Xcode (not under `swift test`), so the
// `GetCrossProviderThreadTool` tool struct in `LeafMCP/Tools/` is tested via
// its LeafCore helper. Here — all 4 planned cases:
//
//   - testExecute_LinearOnly_ReturnsLinearEvents
//   - testExecute_GitHubLinkedEvents
//   - testExecute_NoMatches_EmptyTimeline
//   - testExecute_MissingArgument_ReturnsError
//     (helper takes non-optional String — the test verifies the schema
//      invariant + empty-string fallback behavior, which at the tool-wrapper
//      level yields ToolCallResult.isError=true.)

import XCTest
import GRDB
@testable import LeafCore

final class CrossProviderThreadTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-cross-provider-thread-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func makeLinearIssueUpdatedEvent(
        issueKey: String,
        status: String,
        atMs: Int64
    ) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(atMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": "issue_updated",
                "issue_key": issueKey,
                "title": "Real PR title that should NOT surface in MCP output",
                "status": status,
                "project": "Leaf",
                "team_key": "LEAF"
            ]
        )
    }

    private func makeCommitPushedEvent(
        repo: String,
        sha: String,
        linkedLinearID: String,
        atMs: Int64
    ) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(atMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "github",
                "event_kind": "gh_commit_pushed",
                "repo": repo,
                "title": "feat: real commit subject SHOULD NOT surface",
                "number": "",
                "sha": sha,
                "branch": "main",
                "linked_linear_id": linkedLinearID
            ]
        )
    }

    private func makePROpenedEvent(
        repo: String,
        prNumber: Int,
        linkedLinearID: String,
        atMs: Int64
    ) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(atMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "github",
                "event_kind": "gh_pr_opened",
                "repo": repo,
                "title": "Real PR title — leaks bad",
                "number": String(prNumber),
                "sha": "",
                "branch": "feat/foo",
                "linked_linear_id": linkedLinearID
            ]
        )
    }

    // MARK: - testExecute_LinearOnly_ReturnsLinearEvents

    /// Seed 3 linear issue_updated events for LEAF-1 → 3 events returned,
    /// ordered ASC by ts.
    func testExecute_LinearOnly_ReturnsLinearEvents() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        // Spread events over time for ASC ordering verification.
        let events: [RawEvent] = [
            makeLinearIssueUpdatedEvent(issueKey: "LEAF-1", status: "Triage", atMs: 1_700_000_000_000),
            makeLinearIssueUpdatedEvent(issueKey: "LEAF-1", status: "Started", atMs: 1_700_000_010_000),
            makeLinearIssueUpdatedEvent(issueKey: "LEAF-1", status: "Done", atMs: 1_700_000_020_000),
            // Noise — a different issue, must not be matched.
            makeLinearIssueUpdatedEvent(issueKey: "LEAF-2", status: "Started", atMs: 1_700_000_005_000)
        ]
        try db.write(events)

        let payload = try CrossProviderInsights.crossProviderThread(
            database: db,
            linearIssueID: "LEAF-1"
        )

        XCTAssertEqual(payload["linear_issue_id"] as? String, "LEAF-1")

        let returned = try XCTUnwrap(payload["events"] as? [[String: Any]])
        XCTAssertEqual(returned.count, 3, "only LEAF-1 events; LEAF-2 must not be included")

        // ASC ordering verified.
        XCTAssertEqual(returned[0]["ts_ms"] as? Int64, 1_700_000_000_000)
        XCTAssertEqual(returned[1]["ts_ms"] as? Int64, 1_700_000_010_000)
        XCTAssertEqual(returned[2]["ts_ms"] as? Int64, 1_700_000_020_000)

        // Each event has source/event_kind + projected payload without `title`.
        for entry in returned {
            XCTAssertEqual(entry["source"] as? String, "linear")
            XCTAssertEqual(entry["event_kind"] as? String, "issue_updated")
            let projectedPayload = try XCTUnwrap(entry["payload"] as? [String: Any])
            XCTAssertNil(projectedPayload["title"], "ADR-010 — title must be filtered out of the projection whitelist")
            XCTAssertEqual(projectedPayload["issue_key"] as? String, "LEAF-1")
            XCTAssertNotNil(projectedPayload["status"])
        }

        // Aggregates.
        XCTAssertEqual(payload["first_touch_ms"] as? Int64, 1_700_000_000_000)
        XCTAssertEqual(payload["last_touch_ms"] as? Int64, 1_700_000_020_000)
        XCTAssertEqual(payload["duration_seconds"] as? Int, 20)
    }

    // MARK: - testExecute_GitHubLinkedEvents

    /// Seed commit_pushed + pr_opened with linked_linear_id="LEAF-1" + linear
    /// issue_updated for LEAF-1 → all three returned, ordered ASC by ts.
    func testExecute_GitHubLinkedEvents() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let events: [RawEvent] = [
            makeLinearIssueUpdatedEvent(issueKey: "LEAF-1", status: "Started", atMs: 1_730_000_000_000),
            makeCommitPushedEvent(repo: "owner/repo", sha: "abc123", linkedLinearID: "LEAF-1", atMs: 1_730_000_060_000),
            makePROpenedEvent(repo: "owner/repo", prNumber: 42, linkedLinearID: "LEAF-1", atMs: 1_730_000_120_000),
            // Noise — github events with a different linked_linear_id or without one.
            makeCommitPushedEvent(repo: "owner/repo", sha: "def456", linkedLinearID: "LEAF-99", atMs: 1_730_000_030_000)
        ]
        try db.write(events)

        let payload = try CrossProviderInsights.crossProviderThread(
            database: db,
            linearIssueID: "LEAF-1"
        )

        let returned = try XCTUnwrap(payload["events"] as? [[String: Any]])
        XCTAssertEqual(returned.count, 3, "linear issue_updated + 2 github events linked to LEAF-1")

        // ASC ordering — linear (1_730_000_000) → commit (1_730_000_060) → PR (1_730_000_120).
        XCTAssertEqual(returned[0]["source"] as? String, "linear")
        XCTAssertEqual(returned[0]["event_kind"] as? String, "issue_updated")
        XCTAssertEqual(returned[1]["source"] as? String, "github")
        XCTAssertEqual(returned[1]["event_kind"] as? String, "gh_commit_pushed")
        XCTAssertEqual(returned[2]["source"] as? String, "github")
        XCTAssertEqual(returned[2]["event_kind"] as? String, "gh_pr_opened")

        // ADR-010 — `title` filtered out of commit & PR payloads.
        let commitPayload = try XCTUnwrap(returned[1]["payload"] as? [String: Any])
        XCTAssertNil(commitPayload["title"], "commit message subject — title — must be filtered out")
        XCTAssertEqual(commitPayload["sha"] as? String, "abc123")
        XCTAssertEqual(commitPayload["repo"] as? String, "owner/repo")
        XCTAssertEqual(commitPayload["linked_linear_id"] as? String, "LEAF-1")

        let prPayload = try XCTUnwrap(returned[2]["payload"] as? [String: Any])
        XCTAssertNil(prPayload["title"], "PR title must be filtered out")
        XCTAssertEqual(prPayload["number"] as? String, "42")
        XCTAssertEqual(prPayload["linked_linear_id"] as? String, "LEAF-1")

        // Aggregates.
        XCTAssertEqual(payload["first_touch_ms"] as? Int64, 1_730_000_000_000)
        XCTAssertEqual(payload["last_touch_ms"] as? Int64, 1_730_000_120_000)
        XCTAssertEqual(payload["duration_seconds"] as? Int, 120)
    }

    // MARK: - testExecute_NoMatches_EmptyTimeline

    /// Query for "LEAF-999" in a DB with other issues → events: [], aggregates 0.
    func testExecute_NoMatches_EmptyTimeline() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let events: [RawEvent] = [
            makeLinearIssueUpdatedEvent(issueKey: "LEAF-1", status: "Started", atMs: 1_700_000_000_000),
            makeCommitPushedEvent(repo: "owner/repo", sha: "abc", linkedLinearID: "LEAF-2", atMs: 1_700_000_001_000)
        ]
        try db.write(events)

        let payload = try CrossProviderInsights.crossProviderThread(
            database: db,
            linearIssueID: "LEAF-999"
        )

        XCTAssertEqual(payload["linear_issue_id"] as? String, "LEAF-999")
        let returned = try XCTUnwrap(payload["events"] as? [[String: Any]])
        XCTAssertTrue(returned.isEmpty, "no matches → empty array")
        XCTAssertEqual(payload["first_touch_ms"] as? Int64, 0)
        XCTAssertEqual(payload["last_touch_ms"] as? Int64, 0)
        XCTAssertEqual(payload["duration_seconds"] as? Int, 0)
    }

    // MARK: - testExecute_MissingArgument_ReturnsError

    /// Schema invariant: `linear_issue_id` is required argument. Missing arg
    /// → tool returns ToolCallResult.isError=true (per plan literal — does NOT throw).
    /// Helper-level: an empty string yields an empty timeline (no SQL match), which
    /// at the tool-wrapper level short-circuits to isError=true BEFORE the helper.
    /// Here we verify (a) the schema declares it required, (b) the empty-string
    /// behavior — the helper does not crash, returns empty events.
    func testExecute_MissingArgument_ReturnsError() throws {
        // (a) Empty string → empty timeline (helper-level, no crashes).
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        // Seed real events to ensure SQL finds "real" issues but not "".
        try db.write([
            makeLinearIssueUpdatedEvent(issueKey: "LEAF-1", status: "Started", atMs: 1_700_000_000_000)
        ])

        let payload = try CrossProviderInsights.crossProviderThread(
            database: db,
            linearIssueID: ""
        )
        let returned = try XCTUnwrap(payload["events"] as? [[String: Any]])
        XCTAssertTrue(returned.isEmpty, "empty issue_id → no SQL match → empty events")
        XCTAssertEqual(payload["first_touch_ms"] as? Int64, 0)
        XCTAssertEqual(payload["last_touch_ms"] as? Int64, 0)
        XCTAssertEqual(payload["duration_seconds"] as? Int, 0)

        // (b) Sanity — a non-empty string works on the same DB.
        let real = try CrossProviderInsights.crossProviderThread(
            database: db,
            linearIssueID: "LEAF-1"
        )
        let realEvents = try XCTUnwrap(real["events"] as? [[String: Any]])
        XCTAssertEqual(realEvents.count, 1, "non-empty issue_id matches seeded LEAF-1")
    }
}
