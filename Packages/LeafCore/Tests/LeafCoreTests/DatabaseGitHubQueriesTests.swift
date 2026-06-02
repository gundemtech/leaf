// Phase 4.7.B-3 — Database.queryActiveGitHubRepos helper tests.
// Helper picks the top-N repos (DESC by `commit_pushed` count) for bounded
// fan-out actions/runs polling. SQL: json_extract filter on source=github +
// event_kind=commit_pushed + ts >= sinceMs + repo IS NOT NULL.

import XCTest
@testable import LeafCore

final class DatabaseGitHubQueriesTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-github-queries-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeDB() throws -> Database {
        try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    private func pushEvent(repo: String, atMs: Int64) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(atMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "github",
                "event_kind": "gh_commit_pushed",
                "repo": repo,
                "title": "test",
                "sha": "abc"
            ]
        )
    }

    /// Plan-required: seed events table 12 push events across 3 repos →
    /// query returns top 3 ordered DESC by count.
    /// Distribution: octocat/X1=6, octocat/X2=4, octocat/X3=2 (12 total).
    func testActiveReposQuery_TopNByPushFrequency() throws {
        let db = try makeDB()
        let baseMs: Int64 = 1_700_000_000_000
        var events: [RawEvent] = []
        // 6 pushes to X1, 4 to X2, 2 to X3.
        for i in 0..<6 { events.append(pushEvent(repo: "octocat/X1", atMs: baseMs + Int64(i))) }
        for i in 0..<4 { events.append(pushEvent(repo: "octocat/X2", atMs: baseMs + 100 + Int64(i))) }
        for i in 0..<2 { events.append(pushEvent(repo: "octocat/X3", atMs: baseMs + 200 + Int64(i))) }
        try db.write(events)

        let repos = try db.queryActiveGitHubRepos(sinceMs: baseMs - 1000, limit: 10)
        XCTAssertEqual(repos.count, 3)
        XCTAssertEqual(repos, ["octocat/X1", "octocat/X2", "octocat/X3"], "ordered DESC by push count")
    }

    /// The `limit` parameter actually constrains the result.
    func testActiveReposQuery_RespectsLimit() throws {
        let db = try makeDB()
        let baseMs: Int64 = 1_700_000_000_000
        var events: [RawEvent] = []
        for i in 0..<6 { events.append(pushEvent(repo: "octocat/X1", atMs: baseMs + Int64(i))) }
        for i in 0..<4 { events.append(pushEvent(repo: "octocat/X2", atMs: baseMs + 100 + Int64(i))) }
        for i in 0..<2 { events.append(pushEvent(repo: "octocat/X3", atMs: baseMs + 200 + Int64(i))) }
        try db.write(events)

        let top2 = try db.queryActiveGitHubRepos(sinceMs: baseMs - 1000, limit: 2)
        XCTAssertEqual(top2, ["octocat/X1", "octocat/X2"], "limit=2 → top 2 only")
    }

    /// `sinceMs` cutoff — events before the cutoff are not counted.
    func testActiveReposQuery_SinceCutoffFilters() throws {
        let db = try makeDB()
        let oldMs: Int64 = 1_700_000_000_000
        let newMs: Int64 = 1_800_000_000_000
        try db.write([
            pushEvent(repo: "octocat/old", atMs: oldMs),
            pushEvent(repo: "octocat/old", atMs: oldMs + 1),
            pushEvent(repo: "octocat/new", atMs: newMs)
        ])
        // sinceMs between old and new → only octocat/new.
        let repos = try db.queryActiveGitHubRepos(sinceMs: newMs - 100, limit: 10)
        XCTAssertEqual(repos, ["octocat/new"], "events before sinceMs filtered out")
    }

    /// Non-github events / non-commit_pushed events must NOT end up in the result.
    func testActiveReposQuery_FiltersBySourceAndEventKind() throws {
        let db = try makeDB()
        let baseMs: Int64 = 1_700_000_000_000
        try db.write([
            // github commit_pushed — should count.
            pushEvent(repo: "octocat/A", atMs: baseMs),
            // linear event with repo — should NOT count (source != github).
            RawEvent(
                timestamp: Date(timeIntervalSince1970: TimeInterval(baseMs + 1) / 1000.0),
                signalType: .action,
                bundleID: nil,
                payload: [
                    "source": "linear",
                    "event_kind": "issue_updated",
                    "repo": "octocat/B"
                ]
            ),
            // github pr_opened — should NOT count (event_kind != commit_pushed).
            RawEvent(
                timestamp: Date(timeIntervalSince1970: TimeInterval(baseMs + 2) / 1000.0),
                signalType: .action,
                bundleID: nil,
                payload: [
                    "source": "github",
                    "event_kind": "gh_pr_opened",
                    "repo": "octocat/C"
                ]
            )
        ])

        let repos = try db.queryActiveGitHubRepos(sinceMs: baseMs - 1000, limit: 10)
        XCTAssertEqual(repos, ["octocat/A"], "only github commit_pushed events are counted")
    }

    /// Empty events table → empty result, not an error.
    func testActiveReposQuery_EmptyTable_ReturnsEmpty() throws {
        let db = try makeDB()
        let repos = try db.queryActiveGitHubRepos(sinceMs: 0, limit: 10)
        XCTAssertEqual(repos, [])
    }

    /// `limit <= 0` — defensive guard, not a SQL error.
    func testActiveReposQuery_ZeroLimit_ReturnsEmpty() throws {
        let db = try makeDB()
        try db.write([pushEvent(repo: "octocat/A", atMs: 1_700_000_000_000)])
        let repos = try db.queryActiveGitHubRepos(sinceMs: 0, limit: 0)
        XCTAssertEqual(repos, [])
    }
}
