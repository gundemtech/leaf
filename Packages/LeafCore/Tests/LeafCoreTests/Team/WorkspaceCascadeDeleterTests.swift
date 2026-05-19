// Track 5 / S8 / T8 — WorkspaceCascadeDeleter execute(workspaceID:) cascade
// + idempotency + keystore removal coverage. The pruner-specific edge cases
// live in WorkspaceCascadeDeleterPrunerTests; the audit-invariant fence lives
// in WorkspaceCascadeDeleterAuditInvariantTests.

import XCTest
import CryptoKit
import GRDB
@testable import LeafCore

final class WorkspaceCascadeDeleterTests: XCTestCase {
    private var tempDir: URL!
    private var keystoreRoot: URL!
    private var dbURL: URL!
    private var db: LeafCore.Database!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-cascade-\(UUID().uuidString)")
        keystoreRoot = tempDir.appendingPathComponent("keystore", isDirectory: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
        db = try! LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: nil)
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeService() -> WorkspaceService {
        WorkspaceService(
            database: db,
            keystoreRoot: keystoreRoot,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            randomBytes: { count in Data(repeating: 0x42, count: count) },
            randomUUID: { UUID().uuidString.lowercased() }
        )
    }

    private func makeDeleter() -> WorkspaceCascadeDeleter {
        WorkspaceCascadeDeleter(database: db, keystoreRoot: keystoreRoot)
    }

    private func seedCachedRows(workspaceID wid: String) throws {
        try db.writeSQL { rawDB in
            try rawDB.execute(sql: """
                INSERT INTO \(Schema.MessagesMirror.tableName) (
                    \(Schema.MessagesMirror.messageID),
                    \(Schema.MessagesMirror.workspaceID),
                    \(Schema.MessagesMirror.senderPubkeyHex),
                    \(Schema.MessagesMirror.senderMemberID),
                    \(Schema.MessagesMirror.senderDisplayName),
                    \(Schema.MessagesMirror.recipientPubkeyHex),
                    \(Schema.MessagesMirror.kind),
                    \(Schema.MessagesMirror.body),
                    \(Schema.MessagesMirror.sentAtMs),
                    \(Schema.MessagesMirror.serverCreatedAtMs),
                    \(Schema.MessagesMirror.direction),
                    \(Schema.MessagesMirror.lastSyncedAtMs)
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    UUID().uuidString, wid,
                    String(repeating: "aa", count: 32),
                    UUID().uuidString, "Alice",
                    String(repeating: "bb", count: 32),
                    "handoff", "hello",
                    Int64(1_700_000_000_000),
                    Int64(1_700_000_000_000),
                    Schema.MessagesMirror.directionOutbound,
                    Int64(1_700_000_000_000)
                ]
            )
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
                    UUID().uuidString, wid,
                    String(repeating: "cc", count: 32),
                    Schema.ShareSources.gitCommits, "git_commit",
                    "{}",
                    Int64(1_700_000_000_000),
                    Int64(1_700_000_000_000),
                    Int64(1_700_000_000_000)
                ]
            )
            try rawDB.execute(sql: """
                INSERT INTO \(Schema.ShareRules.tableName) (
                    \(Schema.ShareRules.workspaceID),
                    \(Schema.ShareRules.sourceKind),
                    \(Schema.ShareRules.enabled),
                    \(Schema.ShareRules.updatedAtMs)
                ) VALUES (?, ?, 1, ?)
                """,
                arguments: [wid, Schema.ShareSources.gitCommits, Int64(1_700_000_000_000)]
            )
            try rawDB.execute(sql: """
                INSERT INTO \(Schema.TeamEventBroadcastOffsets.tableName) (
                    \(Schema.TeamEventBroadcastOffsets.workspaceID),
                    \(Schema.TeamEventBroadcastOffsets.cursorEventID),
                    \(Schema.TeamEventBroadcastOffsets.consecutiveFailures)
                ) VALUES (?, 0, 0)
                """,
                arguments: [wid]
            )
            try rawDB.execute(sql: """
                INSERT INTO \(Schema.PendingInvites.tableName) (
                    \(Schema.PendingInvites.token),
                    \(Schema.PendingInvites.workspaceID),
                    \(Schema.PendingInvites.otp),
                    \(Schema.PendingInvites.inviteePubkeyHex),
                    \(Schema.PendingInvites.createdAtMs),
                    \(Schema.PendingInvites.expiresAtMs),
                    \(Schema.PendingInvites.status)
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "tok-\(UUID().uuidString.prefix(8))", wid,
                    "123456",
                    String(repeating: "ab", count: 32),
                    Int64(1_700_000_000_000),
                    Int64(1_700_086_400_000),
                    "pending"
                ]
            )
        }
    }

    private func countRows(table: String, workspaceColumn: String, workspaceID: String) throws -> Int {
        try db.readSQL { rawDB in
            let r = try Row.fetchOne(rawDB,
                sql: "SELECT COUNT(*) as n FROM \(table) WHERE \(workspaceColumn) = ?",
                arguments: [workspaceID])!
            return r["n"]
        }
    }

    // MARK: - Cascade DELETEs

    func testExecute_CascadeDELETES_AllCacheTables() async throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Acme")
        try seedCachedRows(workspaceID: ws.id)

        // Sanity: rows exist before wipe.
        XCTAssertEqual(try countRows(table: Schema.MessagesMirror.tableName, workspaceColumn: Schema.MessagesMirror.workspaceID, workspaceID: ws.id), 1)
        XCTAssertEqual(try countRows(table: Schema.TeamEventsMirror.tableName, workspaceColumn: Schema.TeamEventsMirror.workspaceID, workspaceID: ws.id), 1)
        XCTAssertEqual(try countRows(table: Schema.ShareRules.tableName, workspaceColumn: Schema.ShareRules.workspaceID, workspaceID: ws.id), 1)
        XCTAssertEqual(try countRows(table: Schema.TeamEventBroadcastOffsets.tableName, workspaceColumn: Schema.TeamEventBroadcastOffsets.workspaceID, workspaceID: ws.id), 1)
        XCTAssertEqual(try countRows(table: Schema.PendingInvites.tableName, workspaceColumn: Schema.PendingInvites.workspaceID, workspaceID: ws.id), 1)

        let deleter = makeDeleter()
        try await deleter.execute(workspaceID: ws.id)

        XCTAssertEqual(try countRows(table: Schema.MessagesMirror.tableName, workspaceColumn: Schema.MessagesMirror.workspaceID, workspaceID: ws.id), 0)
        XCTAssertEqual(try countRows(table: Schema.TeamEventsMirror.tableName, workspaceColumn: Schema.TeamEventsMirror.workspaceID, workspaceID: ws.id), 0)
        XCTAssertEqual(try countRows(table: Schema.ShareRules.tableName, workspaceColumn: Schema.ShareRules.workspaceID, workspaceID: ws.id), 0)
        XCTAssertEqual(try countRows(table: Schema.TeamEventBroadcastOffsets.tableName, workspaceColumn: Schema.TeamEventBroadcastOffsets.workspaceID, workspaceID: ws.id), 0)
        XCTAssertEqual(try countRows(table: Schema.PendingInvites.tableName, workspaceColumn: Schema.PendingInvites.workspaceID, workspaceID: ws.id), 0)
    }

    // MARK: - Workspace row

    func testExecute_DeletesWorkspaceRow() async throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Acme")
        XCTAssertNotNil(try db.readWorkspace(id: ws.id))

        let deleter = makeDeleter()
        try await deleter.execute(workspaceID: ws.id)

        XCTAssertNil(try db.readWorkspace(id: ws.id),
                     "workspace row must be deleted by hard-wipe (vs softDelete which keeps it)")
    }

    // MARK: - Keystore wipe

    func testExecute_RemovesKeystoreSubdirectory() async throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Acme")
        let keystoreDir = keystoreRoot
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(ws.id, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keystoreDir.path),
                      "keystore dir should exist before hard-wipe")

        let deleter = makeDeleter()
        try await deleter.execute(workspaceID: ws.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: keystoreDir.path),
                       "keystore dir should be removed after hard-wipe")
    }

    // MARK: - Cross-workspace isolation

    func testExecute_DoesNotAffectOtherWorkspaceData() async throws {
        let svc = makeService()
        let a = try svc.createWorkspace(displayName: "Acme")
        let b = try svc.createWorkspace(displayName: "Beta")
        try seedCachedRows(workspaceID: a.id)
        try seedCachedRows(workspaceID: b.id)

        let deleter = makeDeleter()
        try await deleter.execute(workspaceID: a.id)

        // Workspace B's cache must remain intact.
        XCTAssertEqual(try countRows(table: Schema.MessagesMirror.tableName, workspaceColumn: Schema.MessagesMirror.workspaceID, workspaceID: b.id), 1)
        XCTAssertEqual(try countRows(table: Schema.TeamEventsMirror.tableName, workspaceColumn: Schema.TeamEventsMirror.workspaceID, workspaceID: b.id), 1)
        XCTAssertEqual(try countRows(table: Schema.ShareRules.tableName, workspaceColumn: Schema.ShareRules.workspaceID, workspaceID: b.id), 1)
        XCTAssertEqual(try countRows(table: Schema.TeamEventBroadcastOffsets.tableName, workspaceColumn: Schema.TeamEventBroadcastOffsets.workspaceID, workspaceID: b.id), 1)
        XCTAssertEqual(try countRows(table: Schema.PendingInvites.tableName, workspaceColumn: Schema.PendingInvites.workspaceID, workspaceID: b.id), 1)

        XCTAssertNotNil(try db.readWorkspace(id: b.id),
                        "workspace B row must be untouched")
    }

    // MARK: - Idempotency

    func testExecute_Idempotent_ReCallDoesNotThrow() async throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Acme")
        let deleter = makeDeleter()
        try await deleter.execute(workspaceID: ws.id)
        // Second call: cache rows already gone, workspace row gone, keystore folder gone — all no-op.
        await XCTAssertNoThrowAsync(try await deleter.execute(workspaceID: ws.id))
    }

    // MARK: - hardDelete pair on WorkspaceService

    func testWorkspaceService_hardDelete_DelegatesToDeleter() async throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Acme")
        try seedCachedRows(workspaceID: ws.id)
        let deleter = makeDeleter()

        try await svc.hardDelete(workspaceID: ws.id, via: deleter)

        XCTAssertEqual(try countRows(table: Schema.MessagesMirror.tableName, workspaceColumn: Schema.MessagesMirror.workspaceID, workspaceID: ws.id), 0)
        XCTAssertNil(try db.readWorkspace(id: ws.id))
    }
}

// MARK: - async XCTAssertNoThrow helper

func XCTAssertNoThrowAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
    } catch {
        XCTFail("Expected no throw but got: \(error). \(message())", file: file, line: line)
    }
}
