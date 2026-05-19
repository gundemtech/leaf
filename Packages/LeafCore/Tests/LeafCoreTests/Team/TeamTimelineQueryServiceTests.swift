//
//  TeamTimelineQueryServiceTests.swift
//  LeafCoreTests
//
//  Track 5 / S8 / T7 — service-layer tests for `leaf_query_team` backend.
//  DB-backed; uses a temp SQLCipher DB with the full migrator stack.
//

import XCTest
import GRDB
@testable import LeafCore

final class TeamTimelineQueryServiceTests: XCTestCase {

    private var tempDir: URL!
    private var db: LeafCore.Database!
    private var service: TeamTimelineQueryService!

    // 64-hex pubkey fixtures — distinct + lowercase per canonical storage.
    private let selfPubkey = "1111111111111111111111111111111111111111111111111111111111111111"
    private let alicePubkey = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let bobPubkey   = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private let carolPubkey = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

    private let workspaceID = "ws-001"

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-team-timeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        db = try LeafCore.Database.openForWrite(
            at: dbURL, config: .weakDefaults, encryption: .deterministicTest
        )

        // Seed workspace + members.
        let workspace = Workspace(
            id: workspaceID,
            name: "Test Workspace",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdByMemberID: "self-member-id",
            leftAt: nil
        )
        try db.upsertWorkspace(workspace)
        try db.insertTeamMember(makeMember(id: "self-member-id", pubkey: selfPubkey, name: "Me"))
        try db.insertTeamMember(makeMember(id: "alice-member", pubkey: alicePubkey, name: "Alice"))
        try db.insertTeamMember(makeMember(id: "bob-member",   pubkey: bobPubkey,   name: "Bob"))
        // Carol = duplicate display_name "Alice" to exercise ambiguous-name path.
        try db.insertTeamMember(makeMember(id: "carol-member", pubkey: carolPubkey, name: "Alice"))

        service = TeamTimelineQueryService(
            database: db,
            activeWorkspaceProvider: { [workspaceID] in workspaceID },
            selfPubkeyProvider: { [selfPubkey] in selfPubkey },
            now: { Date(timeIntervalSince1970: 1_700_100_000) }  // fixed clock
        )
    }

    override func tearDown() async throws {
        service = nil
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixture helpers

    private func makeMember(id: String, pubkey: String, name: String) -> TeamMember {
        TeamMember(
            id: id,
            workspaceID: workspaceID,
            role: .member,
            pubkeyHex: pubkey,
            displayName: name,
            addedAt: Date(timeIntervalSince1970: 1_700_000_100),
            removedAt: nil
        )
    }

    private func insertMirror(
        eventID: String,
        sender: String,
        source: ShareSource = .gitCommits,
        kind: String = "gh_commit_pushed",
        payloadJSON: String = #"{"payload":{"fields":{"commit_sha":"abc"}}}"#,
        eventTsMs: Int64,
        serverCreatedAtMs: Int64? = nil,
        workspace: String? = nil
    ) throws {
        let wid = workspace ?? workspaceID
        let row = TeamEventMirrorRow(
            eventID: eventID,
            workspaceID: wid,
            senderPubkeyHex: sender,
            source: source,
            kind: kind,
            plaintextPayloadJSON: payloadJSON,
            serverCreatedAtMs: serverCreatedAtMs ?? (eventTsMs + 100),
            eventTsMs: eventTsMs,
            receivedAtMs: (serverCreatedAtMs ?? (eventTsMs + 100)) + 5
        )
        try db.writeSQL { rawDB in
            try TeamEventMirrorStore.upsert(row, in: rawDB)
        }
    }

    // MARK: - 1. Query by pubkey hex returns events in DESC order

    func testQuery_ByPubkeyHex_ReturnsEventsInDescOrder() async throws {
        try insertMirror(eventID: "e1", sender: alicePubkey, eventTsMs: 1_700_050_000_000)
        try insertMirror(eventID: "e2", sender: alicePubkey, eventTsMs: 1_700_060_000_000)
        try insertMirror(eventID: "e3", sender: alicePubkey, eventTsMs: 1_700_070_000_000)

        let result = try await service.query(member: alicePubkey)

        XCTAssertEqual(result.events.count, 3)
        XCTAssertEqual(result.events.map(\.eventID), ["e3", "e2", "e1"])
        XCTAssertEqual(result.member.pubkey, alicePubkey)
        XCTAssertEqual(result.member.displayName, "Alice")
        XCTAssertEqual(result.workspace.id, workspaceID)
        XCTAssertEqual(result.workspace.name, "Test Workspace")
        XCTAssertEqual(result.totalCount, 3)
        XCTAssertFalse(result.truncated)
    }

    // MARK: - 2. Display-name resolution via local team_members

    func testQuery_ByDisplayName_ResolvesViaLocalTeamMembers() async throws {
        // Bob is unique by display_name; resolution should succeed.
        try insertMirror(eventID: "b1", sender: bobPubkey, eventTsMs: 1_700_080_000_000)

        let result = try await service.query(member: "Bob")

        XCTAssertEqual(result.member.pubkey, bobPubkey)
        XCTAssertEqual(result.member.displayName, "Bob")
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events[0].eventID, "b1")
    }

    func testQuery_ByDisplayName_IsCaseInsensitive() async throws {
        try insertMirror(eventID: "b1", sender: bobPubkey, eventTsMs: 1_700_080_000_000)
        let result = try await service.query(member: "bOb")
        XCTAssertEqual(result.member.pubkey, bobPubkey)
    }

    // MARK: - 3. Ambiguous display name throws

    func testQuery_AmbiguousDisplayName_ThrowsError() async throws {
        // Both Alice and Carol have display_name "Alice".
        do {
            _ = try await service.query(member: "Alice")
            XCTFail("Expected QueryError.ambiguousMemberName")
        } catch TeamTimelineQueryService.QueryError.ambiguousMemberName(let input) {
            XCTAssertEqual(input, "Alice")
        }
    }

    // MARK: - 4. Self-pubkey filter returns empty

    func testQuery_FiltersOutSelfPubkey() async throws {
        try insertMirror(eventID: "self1", sender: selfPubkey, eventTsMs: 1_700_050_000_000)
        try insertMirror(eventID: "self2", sender: selfPubkey, eventTsMs: 1_700_060_000_000)

        let result = try await service.query(member: selfPubkey)

        XCTAssertEqual(result.events.count, 0)
        XCTAssertEqual(result.totalCount, 0)
        XCTAssertEqual(result.member.pubkey, selfPubkey)
        // Sanity: window resolved even on empty path.
        XCTAssertGreaterThan(result.window.untilMs, result.window.sinceMs)
    }

    func testQuery_SelfPubkeyFilter_IsCaseInsensitive() async throws {
        try insertMirror(eventID: "self1", sender: selfPubkey, eventTsMs: 1_700_050_000_000)
        // Upper-cased self pubkey input should still match.
        let upperSelf = selfPubkey.uppercased()
        let result = try await service.query(member: upperSelf)
        XCTAssertEqual(result.events.count, 0)
    }

    // MARK: - 5. Limit cap 500 with truncation flag

    func testQuery_LimitCap500_ExceedingTruncates() async throws {
        // Insert one event so the result is non-empty; assertion targets
        // the truncation flag + clamped limit semantics.
        try insertMirror(eventID: "e1", sender: alicePubkey, eventTsMs: 1_700_080_000_000)

        let result = try await service.query(member: alicePubkey, limit: 1000)

        XCTAssertTrue(result.truncated, "Requests above maxLimit should set truncated=true")
        XCTAssertEqual(result.events.count, 1)  // only one event seeded
    }

    // MARK: - 6. Default limit 100

    func testQuery_DefaultLimit100() async throws {
        // Insert 150 events; expect exactly 100 returned + truncated=false
        // (caller requested default, not above max).
        let baseTs: Int64 = 1_700_050_000_000
        for i in 0..<150 {
            try insertMirror(
                eventID: "e\(i)",
                sender: alicePubkey,
                eventTsMs: baseTs + Int64(i) * 1_000
            )
        }
        let result = try await service.query(member: alicePubkey)
        XCTAssertEqual(result.events.count, TeamTimelineQueryService.defaultLimit)
        XCTAssertFalse(result.truncated, "Default-limit request never sets truncated")
    }

    // MARK: - 7. Kinds filter only returns matching source_kinds

    func testQuery_KindFilter_OnlyMatchingSourceKinds() async throws {
        try insertMirror(
            eventID: "commit1", sender: alicePubkey,
            source: .gitCommits, eventTsMs: 1_700_080_000_000
        )
        try insertMirror(
            eventID: "linear1", sender: alicePubkey,
            source: .linearIssues, eventTsMs: 1_700_080_001_000
        )
        try insertMirror(
            eventID: "slack1", sender: alicePubkey,
            source: .slackMentions, eventTsMs: 1_700_080_002_000
        )

        let result = try await service.query(
            member: alicePubkey,
            kinds: [ShareSource.linearIssues.rawValue]
        )
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events[0].eventID, "linear1")
        XCTAssertEqual(result.events[0].sourceKind, ShareSource.linearIssues.rawValue)
    }

    func testQuery_EmptyKindFilter_ReturnsAllSources() async throws {
        try insertMirror(
            eventID: "commit1", sender: alicePubkey,
            source: .gitCommits, eventTsMs: 1_700_080_000_000
        )
        try insertMirror(
            eventID: "linear1", sender: alicePubkey,
            source: .linearIssues, eventTsMs: 1_700_080_001_000
        )
        let result = try await service.query(member: alicePubkey, kinds: [])
        XCTAssertEqual(result.events.count, 2)
    }

    // MARK: - 8. since/until window filter

    func testQuery_SinceUntilWindow_FiltersOutsideRange() async throws {
        // Three events: one before since, one inside, one after until.
        try insertMirror(eventID: "before", sender: alicePubkey, eventTsMs: 1_700_010_000_000)
        try insertMirror(eventID: "inside", sender: alicePubkey, eventTsMs: 1_700_055_000_000)
        try insertMirror(eventID: "after",  sender: alicePubkey, eventTsMs: 1_700_095_000_000)

        let since = Date(timeIntervalSince1970: 1_700_050_000)  // ms→sec
        let until = Date(timeIntervalSince1970: 1_700_060_000)

        let result = try await service.query(
            member: alicePubkey, since: since, until: until
        )

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events[0].eventID, "inside")
        XCTAssertEqual(result.window.sinceMs, 1_700_050_000_000)
        XCTAssertEqual(result.window.untilMs, 1_700_060_000_000)
    }

    // MARK: - Member-not-found path

    func testQuery_UnknownPubkey_ReturnsEmptyEventsWithUnknownDisplayName() async throws {
        // Unknown 64-hex pubkey is honored (historical events case);
        // displayName falls back to "<unknown>".
        let unknownPubkey = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        let result = try await service.query(member: unknownPubkey)
        XCTAssertEqual(result.member.pubkey, unknownPubkey)
        XCTAssertEqual(result.member.displayName, "<unknown>")
        XCTAssertEqual(result.events.count, 0)
    }

    func testQuery_UnknownDisplayName_ThrowsMemberNotFound() async throws {
        do {
            _ = try await service.query(member: "Dave")
            XCTFail("Expected QueryError.memberNotFound")
        } catch TeamTimelineQueryService.QueryError.memberNotFound(let input) {
            XCTAssertEqual(input, "Dave")
        }
    }

    // MARK: - Cross-workspace isolation

    func testQuery_DoesNotLeakAcrossWorkspaces() async throws {
        // Insert a row in a different workspace; ensure it never appears.
        try insertMirror(
            eventID: "other-ws-event",
            sender: alicePubkey,
            eventTsMs: 1_700_080_000_000,
            workspace: "ws-other"
        )
        try insertMirror(
            eventID: "our-ws-event",
            sender: alicePubkey,
            eventTsMs: 1_700_080_001_000
        )
        let result = try await service.query(member: alicePubkey)
        XCTAssertEqual(result.events.map(\.eventID), ["our-ws-event"])
    }

    // MARK: - Workspace + self pubkey unknown error paths

    func testQuery_WorkspaceUnknown_Throws() async throws {
        let svc = TeamTimelineQueryService(
            database: db,
            activeWorkspaceProvider: { nil },
            selfPubkeyProvider: { [selfPubkey] in selfPubkey }
        )
        do {
            _ = try await svc.query(member: alicePubkey)
            XCTFail("Expected QueryError.workspaceUnknown")
        } catch TeamTimelineQueryService.QueryError.workspaceUnknown {
            // expected
        }
    }

    func testQuery_SelfPubkeyUnknown_Throws() async throws {
        let svc = TeamTimelineQueryService(
            database: db,
            activeWorkspaceProvider: { [workspaceID] in workspaceID },
            selfPubkeyProvider: { nil }
        )
        do {
            _ = try await svc.query(member: alicePubkey)
            XCTFail("Expected QueryError.selfPubkeyUnknown")
        } catch TeamTimelineQueryService.QueryError.selfPubkeyUnknown {
            // expected
        }
    }

    // MARK: - Payload parsing

    func testQuery_ParsesPayloadFieldsFromPlaintextShape() async throws {
        let payloadJSON = #"""
        {
          "event_id": "e1",
          "workspace_id": "ws-001",
          "payload": {
            "fields": {
              "commit_sha": "deadbeef",
              "files_changed_count": "3"
            }
          }
        }
        """#
        try insertMirror(
            eventID: "e1",
            sender: alicePubkey,
            payloadJSON: payloadJSON,
            eventTsMs: 1_700_080_000_000
        )
        let result = try await service.query(member: alicePubkey)
        XCTAssertEqual(result.events.count, 1)
        let payload = result.events[0].payload
        // Only the inner fields are surfaced — envelope keys are stripped.
        XCTAssertEqual(payload["commit_sha"], .string("deadbeef"))
        XCTAssertEqual(payload["files_changed_count"], .string("3"))
        XCTAssertNil(payload["event_id"], "Envelope keys must not leak into payload")
    }
}

// MARK: - Member resolution unit tests (no DB)

final class TeamTimelineQueryServiceMemberResolutionTests: XCTestCase {

    private let pkA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let pkB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    private func makeMember(pubkey: String, name: String) -> TeamMember {
        TeamMember(
            id: UUID().uuidString,
            workspaceID: "ws-001",
            role: .member,
            pubkeyHex: pubkey,
            displayName: name,
            addedAt: Date(),
            removedAt: nil
        )
    }

    func testResolve_PubkeyHex_LowerCase_LooksUpDisplayName() throws {
        let members = [makeMember(pubkey: pkA, name: "Alice")]
        let (pk, name) = try TeamTimelineQueryService.resolveMember(input: pkA, members: members)
        XCTAssertEqual(pk, pkA)
        XCTAssertEqual(name, "Alice")
    }

    func testResolve_PubkeyHex_UpperCase_StillResolves() throws {
        let members = [makeMember(pubkey: pkA, name: "Alice")]
        let (pk, name) = try TeamTimelineQueryService.resolveMember(
            input: pkA.uppercased(), members: members
        )
        // Returned pubkey is normalized to lowercase for consistency
        XCTAssertEqual(pk, pkA)
        XCTAssertEqual(name, "Alice")
    }

    func testResolve_DisplayName_Whitespace_Trimmed() throws {
        let members = [makeMember(pubkey: pkA, name: "Alice")]
        let (_, name) = try TeamTimelineQueryService.resolveMember(
            input: "  Alice  ", members: members
        )
        XCTAssertEqual(name, "Alice")
    }

    func testResolve_DisplayName_Ambiguous_Throws() {
        let members = [
            makeMember(pubkey: pkA, name: "Alice"),
            makeMember(pubkey: pkB, name: "Alice")
        ]
        XCTAssertThrowsError(
            try TeamTimelineQueryService.resolveMember(input: "Alice", members: members)
        ) { error in
            guard case TeamTimelineQueryService.QueryError.ambiguousMemberName(let input) = error else {
                XCTFail("Expected ambiguousMemberName, got \(error)")
                return
            }
            XCTAssertEqual(input, "Alice")
        }
    }

    func testResolve_EmptyInput_Throws() {
        XCTAssertThrowsError(
            try TeamTimelineQueryService.resolveMember(input: "  ", members: [])
        ) { error in
            guard case TeamTimelineQueryService.QueryError.memberNotFound = error else {
                XCTFail("Expected memberNotFound, got \(error)")
                return
            }
        }
    }

    func testResolve_PubkeyOf63Chars_TreatedAsDisplayName() throws {
        // 63 chars (not 64) → not a valid pubkey hex → display-name path.
        let almostHex = String(repeating: "a", count: 63)
        let members = [makeMember(pubkey: pkA, name: almostHex)]
        let (pk, _) = try TeamTimelineQueryService.resolveMember(input: almostHex, members: members)
        XCTAssertEqual(pk, pkA)
    }

    func testResolve_PubkeyHex_NotInMembers_HonoredAsHistorical() throws {
        // Unknown 64-hex pubkey honored — historical-events case where the
        // teammate was removed from the workspace but their mirror rows
        // remain (no UI cleanup landed yet).
        let unknown = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        let (pk, name) = try TeamTimelineQueryService.resolveMember(
            input: unknown, members: []
        )
        XCTAssertEqual(pk, unknown)
        XCTAssertEqual(name, "<unknown>")
    }
}
