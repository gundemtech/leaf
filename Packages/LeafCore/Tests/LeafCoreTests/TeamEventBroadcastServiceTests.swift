// Phase Track-5 S5 — TeamEventBroadcastService.fetchCandidates helper invariants.
// Service-level integration test (full tick path) deferred to acceptance gate
// (needs workspace + team_keys + team_members + keystore scaffolding similar to
// DirectMessageHandshakeIntegrationTests). Coverage here exercises the data
// projection from events.payload_json → BroadcastEventCandidate, which is the
// substrate the broadcast loop relies on.

import XCTest
import GRDB
@testable import LeafCore

final class TeamEventBroadcastServiceTests: XCTestCase {
    private var tempDir: URL!
    private var db: LeafCore.Database!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-broadcast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        db = try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func insertEvent(payloadJSON: String, tsMs: Int64) throws {
        try db.writeSQL { rawDB in
            try rawDB.execute(
                sql: "INSERT INTO events (ts, signal_type, payload_json) VALUES (?, ?, ?)",
                arguments: [tsMs, "attention", payloadJSON]
            )
        }
    }

    func testFetchCandidates_ReturnsEmptyForFreshCursor() throws {
        let candidates = try db.readSQL { rawDB in
            try TeamEventBroadcastService.fetchCandidates(afterEventID: 0, limit: 100, in: rawDB)
        }
        XCTAssertEqual(candidates.count, 0)
    }

    func testFetchCandidates_ParsesEventKindFromPayload() throws {
        try insertEvent(
            payloadJSON: #"{"event_kind":"gh_commit_pushed","commit_sha":"abc"}"#,
            tsMs: 1_000
        )
        let candidates = try db.readSQL { rawDB in
            try TeamEventBroadcastService.fetchCandidates(afterEventID: 0, limit: 100, in: rawDB)
        }
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].eventKind, "gh_commit_pushed")
        XCTAssertEqual(candidates[0].tsMs, 1_000)
        XCTAssertEqual(candidates[0].payload["commit_sha"], "abc")
    }

    func testFetchCandidates_DropsEventsWithoutEventKind() throws {
        try insertEvent(
            payloadJSON: #"{"some_other_key":"value"}"#,
            tsMs: 1_000
        )
        let candidates = try db.readSQL { rawDB in
            try TeamEventBroadcastService.fetchCandidates(afterEventID: 0, limit: 100, in: rawDB)
        }
        XCTAssertEqual(candidates.count, 0)
    }

    func testFetchCandidates_RespectsCursor() throws {
        try insertEvent(payloadJSON: #"{"event_kind":"gh_commit_pushed"}"#, tsMs: 1_000)
        try insertEvent(payloadJSON: #"{"event_kind":"issue_updated"}"#, tsMs: 2_000)
        try insertEvent(payloadJSON: #"{"event_kind":"slack_mention_received"}"#, tsMs: 3_000)

        // Get all 3.
        let all = try db.readSQL { rawDB in
            try TeamEventBroadcastService.fetchCandidates(afterEventID: 0, limit: 100, in: rawDB)
        }
        XCTAssertEqual(all.count, 3)
        let firstID = all[0].id

        // Cursor at first id → returns only second + third.
        let rest = try db.readSQL { rawDB in
            try TeamEventBroadcastService.fetchCandidates(afterEventID: firstID, limit: 100, in: rawDB)
        }
        XCTAssertEqual(rest.count, 2)
        XCTAssertEqual(Set(rest.map { $0.eventKind }), ["issue_updated", "slack_mention_received"])
    }

    func testFetchCandidates_HonorsLimit() throws {
        for i in 0..<10 {
            try insertEvent(payloadJSON: #"{"event_kind":"gh_commit_pushed","i":"\#(i)"}"#, tsMs: Int64(i * 100))
        }
        let batch = try db.readSQL { rawDB in
            try TeamEventBroadcastService.fetchCandidates(afterEventID: 0, limit: 3, in: rawDB)
        }
        XCTAssertEqual(batch.count, 3)
    }

    func testFetchCandidates_CoercesNonStringValuesToString() throws {
        try insertEvent(
            payloadJSON: #"{"event_kind":"gh_pr_opened","pr_number":142,"is_draft":false}"#,
            tsMs: 1_000
        )
        let candidates = try db.readSQL { rawDB in
            try TeamEventBroadcastService.fetchCandidates(afterEventID: 0, limit: 100, in: rawDB)
        }
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].payload["pr_number"], "142")
        // Booleans either coerce to "true"/"false" or are skipped — both acceptable.
    }

    func testUuidStringToRawBytes_StableLength() {
        let data = TeamEventBroadcastService.uuidStringToRawBytes("11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(data.count, 16)
    }

    func testUuidStringToRawBytes_FallbackOnGarbage() {
        let data = TeamEventBroadcastService.uuidStringToRawBytes("not-a-uuid")
        XCTAssertEqual(data.count, 16)
        XCTAssertEqual(data, Data(repeating: 0, count: 16))
    }
}
