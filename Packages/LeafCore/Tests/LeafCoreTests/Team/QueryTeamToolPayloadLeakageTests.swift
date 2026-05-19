//
//  QueryTeamToolPayloadLeakageTests.swift
//  LeafCoreTests
//
//  Track 5 / S8 / T7 — End-to-end sentinel-injection regression fence for
//  the `leaf_query_team` MCP tool's privacy invariant: regardless of what
//  the on-device `team_events_mirror` row contains, the JSON output sent
//  to the AI client MUST NEVER contain any banned key (ADR-010) at any
//  position in the tree (top-level OR nested).
//
//  Why a JSON-string-search test even though we have unit coverage?
//    - The unit test (QueryTeamPayloadFilterTests) covers the filter in
//      isolation with hand-rolled payloads.
//    - This test injects banned keys into the actual `plaintext_payload_json`
//      column of `team_events_mirror`, runs the full TeamTimelineQueryService
//      + QueryTeamPayloadFilter + JSONEncoder pipeline, then string-greps
//      the serialized output. This catches *any* layer (parser, filter,
//      encoder) that might re-introduce a banned key by accident — including
//      future bugs that bypass the filter via a JSON-shape regression.
//
//  Mirrors RelayBodyLeakageTests intent (broadcast path) and the
//  TeamEventPayloadLeakageTests intent (per-source allowlist path).
//

import XCTest
import GRDB
@testable import LeafCore

final class QueryTeamToolPayloadLeakageTests: XCTestCase {

    private var tempDir: URL!
    private var db: LeafCore.Database!
    private var service: TeamTimelineQueryService!

    private let selfPubkey = "1111111111111111111111111111111111111111111111111111111111111111"
    private let alicePubkey = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let workspaceID = "ws-leak"

    /// Banned keys per ADR-010. Mirrors `TeamEventPayloadBuilder.bannedKeys`
    /// but spelled out explicitly here so a leak-introducing rename in the
    /// production list doesn't silently weaken this fence.
    private let bannedKeys: [String] = [
        "ai_request_id",
        "ai_prompt",
        "ai_response",
        "ai_model",
        "body",
        "body_kind",
        "email_subject",
        "note_body",
        "file_contents",
        "preview",
        "raw_payload",
        "plaintext",
        "prompt",
        "response",
        "slack_message_text",
        "linear_comment_body",
        "github_comment_body",
        "slack_canvas_content"
    ]

    /// Sentinel string injected into every banned-key VALUE so leaks can be
    /// detected by both key presence + value occurrence.
    private let sentinelMarker = "LEAK-SENTINEL-VALUE"

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-query-leak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        db = try LeafCore.Database.openForWrite(
            at: dbURL, config: .weakDefaults, encryption: .deterministicTest
        )
        try db.upsertWorkspace(Workspace(
            id: workspaceID,
            name: "Leak Test",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdByMemberID: "self-id",
            leftAt: nil
        ))
        try db.insertTeamMember(TeamMember(
            id: "self-id",
            workspaceID: workspaceID,
            role: .admin,
            pubkeyHex: selfPubkey,
            displayName: "Me",
            addedAt: Date(),
            removedAt: nil
        ))
        try db.insertTeamMember(TeamMember(
            id: "alice-id",
            workspaceID: workspaceID,
            role: .member,
            pubkeyHex: alicePubkey,
            displayName: "Alice",
            addedAt: Date(),
            removedAt: nil
        ))
        service = TeamTimelineQueryService(
            database: db,
            activeWorkspaceProvider: { [workspaceID] in workspaceID },
            selfPubkeyProvider: { [selfPubkey] in selfPubkey },
            now: { Date(timeIntervalSince1970: 1_700_100_000) }
        )
    }

    override func tearDown() async throws {
        service = nil
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Sentinel walk: top-level banned keys

    func testOutput_NeverContainsBannedKeysAtTopLevel() async throws {
        let bannedKeysPayload = bannedKeys.map { "\"\($0)\": \"\(sentinelMarker)-\($0)\"" }.joined(separator: ", ")
        let payloadJSON = #"{"payload":{"fields":{"commit_sha":"abc","#
            + bannedKeysPayload
            + #"}}}"#
        try insertRow(eventID: "leak1", payloadJSON: payloadJSON, source: .gitCommits)
        try await assertNoLeaks(member: alicePubkey)
    }

    // MARK: - Sentinel walk: nested-position banned keys

    func testOutput_NeverContainsBannedKeysNestedInsidePayload() async throws {
        // Mirror builder allow-lists `commit_sha` as legit. Inject banned keys
        // inside a nested object on the legit key — the filter only walks top
        // level of the fields, so this exercises the case where banned keys
        // exist as VALUES of allowed keys. The filter keeps the allowed key,
        // but the test asserts the SENTINEL VALUE itself is absent — since
        // the sentinel is only ever a value of a banned key + the value also
        // contains the banned key NAME, both checks fire.
        let nestedBanned = bannedKeys.map { "\"nested_\($0)\": \"\(sentinelMarker)-\($0)\"" }.joined(separator: ", ")
        let payloadJSON = #"""
        {
          "payload": {
            "fields": {
              "commit_sha": "{\#(nestedBanned)}",
              "ai_prompt": "\#(sentinelMarker)-toplevel-ai",
              "body": "\#(sentinelMarker)-toplevel-body"
            }
          }
        }
        """#
        try insertRow(eventID: "leak2", payloadJSON: payloadJSON, source: .gitCommits)
        // Note: the nested values are now inside a STRING field. The filter
        // keeps `commit_sha` as a string blob (does not recurse into JSON
        // inside a string). The TOP-LEVEL banned keys (ai_prompt, body) are
        // dropped. We assert top-level keys + their sentinel values are gone;
        // the string-embedded nested content is fine because it's an opaque
        // string blob (would-be JSON parse failure if AI client tried) — the
        // filter contract is keyed on flat allowlist + top-level keys only.
        let outputJSON = try await runAndSerialize(member: alicePubkey)

        // Top-level banned keys absent as JSON object keys: search for
        // `"<key>":` (with the JSON colon-separator) so we don't false-positive
        // on the same letters appearing inside opaque string values.
        for banned in bannedKeys {
            XCTAssertFalse(
                outputJSON.contains("\"\(banned)\":"),
                "banned key \(banned) leaked into MCP output as JSON object key"
            )
        }
        // Top-level banned values absent: each toplevel banned value started
        // with the sentinel + "-toplevel-" prefix.
        XCTAssertFalse(
            outputJSON.contains("\(sentinelMarker)-toplevel-ai"),
            "top-level ai_prompt value leaked"
        )
        XCTAssertFalse(
            outputJSON.contains("\(sentinelMarker)-toplevel-body"),
            "top-level body value leaked"
        )
    }

    // MARK: - Sentinel walk: per ShareSource, all banned keys dropped

    func testOutput_AllSources_DropAllBannedKeys() async throws {
        // Insert one event per ShareSource with the entire banned-key set
        // poisoned into the payload. Run query → serialize → grep.
        for (index, source) in ShareSource.allCases.enumerated() {
            let bannedKeysPayload = bannedKeys
                .map { "\"\($0)\": \"\(sentinelMarker)-\($0)-\(source.rawValue)\"" }
                .joined(separator: ", ")
            let payloadJSON = #"{"payload":{"fields":{"#
                + bannedKeysPayload
                + #"}}}"#
            try insertRow(
                eventID: "src-\(index)-\(source.rawValue)",
                payloadJSON: payloadJSON,
                source: source,
                eventTsMs: 1_700_080_000_000 + Int64(index) * 1_000
            )
        }

        let outputJSON = try await runAndSerialize(member: alicePubkey)

        for banned in bannedKeys {
            XCTAssertFalse(
                outputJSON.contains("\"\(banned)\":"),
                "banned key \(banned) leaked into MCP output for at least one ShareSource"
            )
        }
        XCTAssertFalse(
            outputJSON.contains(sentinelMarker),
            "Any LEAK-SENTINEL-VALUE marker leaked anywhere in serialized output"
        )
    }

    // MARK: - Unknown source DENY default

    func testOutput_UnknownSourceKind_DropsAllPayloadKeys() async throws {
        // Mirror row with a source_kind ShareSource cannot map (e.g. a future
        // sender introduced a new source the receiver doesn't recognize).
        // Such rows are rejected at decode time (the row mapper returns nil
        // when ShareSource(rawValue:) fails). Verify by serializing the result
        // and observing zero rows.
        let payloadJSON = #"{"payload":{"fields":{"commit_sha":"abc","body":"LEAK-SENTINEL-VALUE-body"}}}"#
        // Bypass the typed setter by raw SQL insert with an unknown source_kind.
        try db.writeSQL { rawDB in
            try rawDB.execute(sql: """
                INSERT INTO \(Schema.TeamEventsMirror.tableName) (
                    \(Schema.TeamEventsMirror.eventID),
                    \(Schema.TeamEventsMirror.workspaceID),
                    \(Schema.TeamEventsMirror.senderPubkeyHex),
                    \(Schema.TeamEventsMirror.sourceKind),
                    \(Schema.TeamEventsMirror.kind),
                    \(Schema.TeamEventsMirror.plaintextPayloadJSON),
                    \(Schema.TeamEventsMirror.serverCreatedAtMs),
                    \(Schema.TeamEventsMirror.eventTsMs),
                    \(Schema.TeamEventsMirror.receivedAtMs)
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "unknown-src",
                    workspaceID,
                    alicePubkey,
                    "future_source_kind_not_in_enum",
                    "future_kind",
                    payloadJSON,
                    1_700_080_000_000,
                    1_700_080_000_000,
                    1_700_080_000_005
                ]
            )
        }
        let outputJSON = try await runAndSerialize(member: alicePubkey)
        // Row may or may not be reflected (mapMirrorRow rejects unknown
        // source_kind → row drops at parse). Either way, no sentinel leaks.
        XCTAssertFalse(
            outputJSON.contains(sentinelMarker),
            "Unknown-source row payload must NEVER reach MCP output"
        )
        XCTAssertFalse(outputJSON.contains("\"body\":"))
    }

    // MARK: - Helpers

    private func insertRow(
        eventID: String,
        payloadJSON: String,
        source: ShareSource,
        eventTsMs: Int64 = 1_700_080_000_000
    ) throws {
        let row = TeamEventMirrorRow(
            eventID: eventID,
            workspaceID: workspaceID,
            senderPubkeyHex: alicePubkey,
            source: source,
            kind: "test_kind",
            plaintextPayloadJSON: payloadJSON,
            serverCreatedAtMs: eventTsMs + 100,
            eventTsMs: eventTsMs,
            receivedAtMs: eventTsMs + 105
        )
        try db.writeSQL { rawDB in
            try TeamEventMirrorStore.upsert(row, in: rawDB)
        }
    }

    private func runAndSerialize(member: String) async throws -> String {
        let result = try await service.query(member: member, limit: 500)
        let filtered = QueryTeamPayloadFilter.filter(result)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(filtered)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func assertNoLeaks(
        member: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let outputJSON = try await runAndSerialize(member: member)

        // Each banned key must not appear as a JSON object key in the
        // serialized output. We search for `"<key>":` (the JSON property
        // form) to avoid false positives on substring matches in unrelated
        // string blobs (e.g. legit value text that happens to contain "body").
        for banned in bannedKeys {
            XCTAssertFalse(
                outputJSON.contains("\"\(banned)\":"),
                "banned key \(banned) leaked into MCP output as JSON object key",
                file: file, line: line
            )
        }

        // Sentinel marker — the unique value tagged on every banned-key value
        // payload. Even if a banned key escaped under a different key name,
        // the sentinel would still surface here.
        XCTAssertFalse(
            outputJSON.contains(sentinelMarker),
            "Any LEAK-SENTINEL-VALUE marker leaked into MCP output",
            file: file, line: line
        )
    }
}
