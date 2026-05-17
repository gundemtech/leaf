// Phase Track-1 D3 — QueryEngine.currentWork projection tests.
//
// Verifies latest-event projections (current_app, current_branch, current_file,
// in_progress_linear_ticket, last_commit), unresolved-only filtering for
// open_questions / blockers, and where_stopped 24h-window rule.

import GRDB
import XCTest

@testable import LeafCore

final class QueryEngineCurrentWorkTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private let nowMs: Int64 = 10_000_000

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-d3-current-work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func openWriter() throws -> LeafCore.Database {
        try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    private func makeEngine() -> QueryEngine {
        QueryEngine(
            dbURL: dbURL,
            dbConfig: .weakDefaults,
            dbEncryption: .deterministicTest,
            detectorMoat: .publicSubstrate
        )
    }

    private func writeEvent(
        _ db: LeafCore.Database,
        tsMs: Int64,
        signalType: SignalType = .action,
        bundleID: String? = "test.bundle",
        payload: [String: String]
    ) throws {
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000.0),
            signalType: signalType,
            bundleID: bundleID,
            payload: payload
        )
        try db.write(event)
    }

    // MARK: - 1. current_app from latest attention event

    func testCurrentApp_FromLatestNSWorkspaceEvent() throws {
        let db = try openWriter()
        try writeEvent(
            db, tsMs: 1_000, signalType: .attention,
            bundleID: "com.apple.dt.Xcode",
            payload: ["event_kind": "app_focused"])
        try writeEvent(
            db, tsMs: 2_000, signalType: .attention,
            bundleID: "com.tinyspeck.slackmacgap",
            payload: ["event_kind": "app_focused"])
        let r = try makeEngine().currentWork(nowMs: nowMs)
        XCTAssertEqual(r.currentApp, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(r.schemaVersion, "1.0")
    }

    // MARK: - 2. current_branch from latest commit_pushed

    func testCurrentBranch_FromLatestCommitPushed() throws {
        let db = try openWriter()
        try writeEvent(
            db, tsMs: 1_000,
            payload: [
                "event_kind": "gh_commit_pushed",
                "branch": "main",
                Schema.EventPayloadKeys.body: "old commit",
            ])
        try writeEvent(
            db, tsMs: 5_000,
            payload: [
                "event_kind": "gh_commit_pushed",
                "branch": "feature/track-1-D3",
                Schema.EventPayloadKeys.body: "newer commit",
            ])
        let r = try makeEngine().currentWork(nowMs: nowMs)
        XCTAssertEqual(r.currentBranch, "feature/track-1-D3")
    }

    // MARK: - 3. current_file from latest attention with window_title

    func testCurrentFile_FromLatestAXWindow() throws {
        let db = try openWriter()
        try writeEvent(
            db, tsMs: 1_000, signalType: .attention,
            bundleID: "com.apple.dt.Xcode",
            payload: [
                "event_kind": "app_focused",
                "window_title": "QueryEngine.swift — Leaf",
            ])
        try writeEvent(
            db, tsMs: 2_000, signalType: .attention,
            bundleID: "com.apple.dt.Xcode",
            payload: [
                "event_kind": "app_focused",
                "window_title": "QueryEngineTypes.swift — Leaf",
            ])
        let r = try makeEngine().currentWork(nowMs: nowMs)
        XCTAssertEqual(r.currentFile, "QueryEngineTypes.swift — Leaf")
    }

    // MARK: - 4. inProgressLinearTicket from latest issue_updated

    func testInProgressLinearTicket_FromLatestIssueUpdated() throws {
        let db = try openWriter()
        // Older ticket — should NOT win.
        try writeEvent(
            db, tsMs: 1_000,
            payload: [
                "event_kind": "issue_updated",
                "issue_key": "LEAF-10",
                "title": "Old ticket",
                "status": "In Progress",
            ])
        // Newest ticket but Done — must be excluded.
        try writeEvent(
            db, tsMs: 5_000,
            payload: [
                "event_kind": "issue_updated",
                "issue_key": "LEAF-20",
                "title": "Done ticket",
                "status": "Done",
            ])
        // Latest non-Done — should win.
        try writeEvent(
            db, tsMs: 4_000,
            payload: [
                "event_kind": "issue_updated",
                "issue_key": "LEAF-15",
                "title": "Active ticket",
                "status": "In Progress",
            ])
        let r = try makeEngine().currentWork(nowMs: nowMs)
        XCTAssertEqual(r.inProgressLinearTicket?.issueRef, "LEAF-15")
        XCTAssertEqual(r.inProgressLinearTicket?.title, "Active ticket")
        XCTAssertEqual(r.inProgressLinearTicket?.stateName, "In Progress")
    }

    // MARK: - 5. last_commit from latest commit_pushed

    func testLastCommit_FromLatestCommitPushed() throws {
        let db = try openWriter()
        try writeEvent(
            db, tsMs: 1_000,
            payload: [
                "event_kind": "gh_commit_pushed",
                "sha": "abc123",
                "branch": "main",
                Schema.EventPayloadKeys.body: "old commit",
            ])
        try writeEvent(
            db, tsMs: 7_000,
            payload: [
                "event_kind": "gh_commit_pushed",
                "sha": "def456",
                "branch": "feature/x",
                Schema.EventPayloadKeys.body: "latest commit message",
            ])
        let r = try makeEngine().currentWork(nowMs: nowMs)
        XCTAssertEqual(r.lastCommit?.sha, "def456")
        XCTAssertEqual(r.lastCommit?.branch, "feature/x")
        XCTAssertEqual(r.lastCommit?.message, "latest commit message")
        XCTAssertEqual(r.lastCommit?.pushedAtMs, 7_000)
    }

    // MARK: - 6. currentOpenQuestions filters resolved

    func testCurrentOpenQuestions_FiltersResolved() throws {
        let db = try openWriter()
        try db.writeSQL { rawDB in
            // Need a real event row for FK semantics (event_id NOT NULL UNIQUE).
            try rawDB.execute(
                sql: """
                        INSERT INTO events (ts, signal_type, bundle_id, payload_json)
                        VALUES (1000, 'action', 't', '{}'),
                               (2000, 'action', 't', '{}')
                    """)
            try rawDB.execute(
                sql: """
                        INSERT INTO open_questions
                            (event_id, question_excerpt, opened_at_ms)
                        VALUES (1, 'Should we ship Friday?', 1000)
                    """)
            try rawDB.execute(
                sql: """
                        INSERT INTO open_questions
                            (event_id, question_excerpt, opened_at_ms,
                             resolved_at_ms, resolved_by_event_id)
                        VALUES (2, 'Old resolved question', 500, 2000, 2)
                    """)
        }
        let r = try makeEngine().currentWork(nowMs: nowMs)
        XCTAssertEqual(r.currentOpenQuestions.count, 1)
        XCTAssertEqual(r.currentOpenQuestions.first?.questionExcerpt, "Should we ship Friday?")
    }

    // MARK: - 7. currentBlockers filters resolved

    func testCurrentBlockers_FiltersResolved() throws {
        let db = try openWriter()
        try db.writeSQL { rawDB in
            try rawDB.execute(
                sql: """
                        INSERT INTO blockers
                            (target_kind, target_ref, blocker_kind, started_at_ms)
                        VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    Schema.TargetKinds.linearIssue, "LEAF-1",
                    Schema.BlockerKinds.linearStuck, 1_000,
                ])
            try rawDB.execute(
                sql: """
                        INSERT INTO blockers
                            (target_kind, target_ref, blocker_kind, started_at_ms,
                             resolved_at_ms)
                        VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    Schema.TargetKinds.linearIssue, "LEAF-2",
                    Schema.BlockerKinds.linearStuck, 1_000, 2_000,
                ])
        }
        let r = try makeEngine().currentWork(nowMs: nowMs)
        XCTAssertEqual(r.currentBlockers.count, 1)
        XCTAssertEqual(r.currentBlockers.first?.targetRef, "LEAF-1")
    }

    // MARK: - 8. where_stopped — latest within last 24h only

    func testWhereStopped_LatestSameDayOnly() throws {
        let db = try openWriter()
        let oneDayMs: Int64 = 24 * 60 * 60 * 1000

        // First, an old snapshot (>24h before nowMs) — must be excluded.
        try db.writeSQL { rawDB in
            try WhereStoppedLogStore.append(
                WhereStoppedOutput(
                    excerpt: "old digest",
                    wipSignals: WipSignals(commitWip: false, ciFailing: false, midEdit: false),
                    anchorEventID: nil
                ),
                generatedAtMs: nowMs - oneDayMs - 1,
                in: rawDB
            )
        }
        let rOldOnly = try makeEngine().currentWork(nowMs: nowMs)
        XCTAssertNil(rOldOnly.whereStopped, "Snapshot older than 24h must not surface")

        // Now add a recent snapshot — should be returned.
        try db.writeSQL { rawDB in
            try WhereStoppedLogStore.append(
                WhereStoppedOutput(
                    excerpt: "fresh digest",
                    wipSignals: WipSignals(commitWip: true, ciFailing: false, midEdit: true),
                    anchorEventID: 42
                ),
                generatedAtMs: nowMs - 1_000,
                in: rawDB
            )
        }
        let rFresh = try makeEngine().currentWork(nowMs: nowMs)
        XCTAssertEqual(rFresh.whereStopped?.excerpt, "fresh digest")
        XCTAssertEqual(rFresh.whereStopped?.anchorEventID, 42)
        XCTAssertEqual(rFresh.whereStopped?.wipSignals.commitWip, true)
    }
}
