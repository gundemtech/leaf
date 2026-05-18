// Track 5 / S7 E.2 — WorkspaceService.softDelete unit tests.
// TDD: tests written before implementation.

import XCTest
import CryptoKit
import GRDB
@testable import LeafCore

final class WorkspaceServiceSoftDeleteTests: XCTestCase {
    private var tempDir: URL!
    private var keystoreRoot: URL!
    private var dbURL: URL!
    private var db: LeafCore.Database!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-softdel-\(UUID().uuidString)")
        keystoreRoot = tempDir.appendingPathComponent("keystore", isDirectory: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
        db = try! Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: nil)
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

    private let deleteDate = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - deleted_at_ms

    func testSoftDelete_SetsDeletedAtMs() throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Acme")
        try svc.softDelete(workspaceID: ws.id, at: deleteDate)
        let deletedAtMs: Int64? = try db.readSQL { rawDB in
            let r = try Row.fetchOne(rawDB,
                sql: "SELECT \(Schema.Workspaces.deletedAtMs) FROM \(Schema.Workspaces.tableName) WHERE \(Schema.Workspaces.id) = ?",
                arguments: [ws.id])
            return r?[Schema.Workspaces.deletedAtMs]
        }
        XCTAssertNotNil(deletedAtMs)
        XCTAssertEqual(deletedAtMs, Int64(deleteDate.timeIntervalSince1970 * 1000))
    }

    // MARK: - Cascade DELETEs

    func testSoftDelete_CascadeDELETES_MessagesMirror() throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Acme")
        let senderPubkey = String(repeating: "aa", count: 32)
        let recipientPubkey = String(repeating: "bb", count: 32)
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
                    UUID().uuidString, ws.id,
                    senderPubkey, UUID().uuidString, "Alice",
                    recipientPubkey,
                    "handoff", "hello",
                    Int64(1_700_000_000_000),
                    Int64(1_700_000_000_000),
                    Schema.MessagesMirror.directionOutbound,
                    Int64(1_700_000_000_000)
                ]
            )
        }
        let before: Int = try db.readSQL { rawDB in
            let r = try Row.fetchOne(rawDB,
                sql: "SELECT COUNT(*) as n FROM \(Schema.MessagesMirror.tableName) WHERE \(Schema.MessagesMirror.workspaceID) = ?",
                arguments: [ws.id])!
            return r["n"]
        }
        XCTAssertEqual(before, 1)

        try svc.softDelete(workspaceID: ws.id, at: deleteDate)

        let after: Int = try db.readSQL { rawDB in
            let r = try Row.fetchOne(rawDB,
                sql: "SELECT COUNT(*) as n FROM \(Schema.MessagesMirror.tableName) WHERE \(Schema.MessagesMirror.workspaceID) = ?",
                arguments: [ws.id])!
            return r["n"]
        }
        XCTAssertEqual(after, 0)
    }

    func testSoftDelete_CascadeDELETES_TeamEventsMirror() throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Acme")
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
                    UUID().uuidString, ws.id,
                    String(repeating: "aa", count: 32),
                    Schema.ShareSources.gitCommits, "git_commit",
                    "{}", Int64(1_700_000_000_000), Int64(1_700_000_000_000), Int64(1_700_000_000_000)
                ]
            )
        }
        try svc.softDelete(workspaceID: ws.id, at: deleteDate)
        let after: Int = try db.readSQL { rawDB in
            let r = try Row.fetchOne(rawDB,
                sql: "SELECT COUNT(*) as n FROM \(Schema.TeamEventsMirror.tableName) WHERE \(Schema.TeamEventsMirror.workspaceID) = ?",
                arguments: [ws.id])!
            return r["n"]
        }
        XCTAssertEqual(after, 0)
    }

    func testSoftDelete_CascadeDELETES_ShareRules() throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Acme")
        try db.writeSQL { rawDB in
            try rawDB.execute(sql: """
                INSERT INTO \(Schema.ShareRules.tableName) (
                    \(Schema.ShareRules.workspaceID),
                    \(Schema.ShareRules.sourceKind),
                    \(Schema.ShareRules.enabled),
                    \(Schema.ShareRules.updatedAtMs)
                ) VALUES (?, ?, 1, ?)
                """,
                arguments: [ws.id, Schema.ShareSources.gitCommits, Int64(1_700_000_000_000)]
            )
        }
        try svc.softDelete(workspaceID: ws.id, at: deleteDate)
        let after: Int = try db.readSQL { rawDB in
            let r = try Row.fetchOne(rawDB,
                sql: "SELECT COUNT(*) as n FROM \(Schema.ShareRules.tableName) WHERE \(Schema.ShareRules.workspaceID) = ?",
                arguments: [ws.id])!
            return r["n"]
        }
        XCTAssertEqual(after, 0)
    }

    func testSoftDelete_CascadeDELETES_PendingInvites() throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Acme")
        try db.writeSQL { rawDB in
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
                    "tok123", ws.id,
                    "123456",
                    String(repeating: "ab", count: 32),
                    Int64(1_700_000_000_000),
                    Int64(1_700_086_400_000),
                    "pending"
                ]
            )
        }
        try svc.softDelete(workspaceID: ws.id, at: deleteDate)
        let after: Int = try db.readSQL { rawDB in
            let r = try Row.fetchOne(rawDB,
                sql: "SELECT COUNT(*) as n FROM \(Schema.PendingInvites.tableName) WHERE \(Schema.PendingInvites.workspaceID) = ?",
                arguments: [ws.id])!
            return r["n"]
        }
        XCTAssertEqual(after, 0)
    }

    func testSoftDelete_CascadeDELETES_TeamEventBroadcastOffsets() throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Acme")
        try db.writeSQL { rawDB in
            try rawDB.execute(sql: """
                INSERT INTO \(Schema.TeamEventBroadcastOffsets.tableName) (
                    \(Schema.TeamEventBroadcastOffsets.workspaceID),
                    \(Schema.TeamEventBroadcastOffsets.cursorEventID),
                    \(Schema.TeamEventBroadcastOffsets.consecutiveFailures)
                ) VALUES (?, 0, 0)
                """,
                arguments: [ws.id]
            )
        }
        try svc.softDelete(workspaceID: ws.id, at: deleteDate)
        let after: Int = try db.readSQL { rawDB in
            let r = try Row.fetchOne(rawDB,
                sql: "SELECT COUNT(*) as n FROM \(Schema.TeamEventBroadcastOffsets.tableName) WHERE \(Schema.TeamEventBroadcastOffsets.workspaceID) = ?",
                arguments: [ws.id])!
            return r["n"]
        }
        XCTAssertEqual(after, 0)
    }

    // MARK: - Keystore

    func testSoftDelete_RemovesKeystoreSubdirectory() throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Acme")
        let keystoreDir = keystoreRoot
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(ws.id, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keystoreDir.path),
                      "keystore dir should exist before soft-delete")
        try svc.softDelete(workspaceID: ws.id, at: deleteDate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keystoreDir.path),
                       "keystore dir should be removed after soft-delete")
    }

    // MARK: - Idempotency

    func testSoftDelete_Idempotent_ReCallDoesNotThrow() throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Acme")
        try svc.softDelete(workspaceID: ws.id, at: deleteDate)
        // Second call — no rows to delete, no-op — must not throw.
        XCTAssertNoThrow(try svc.softDelete(workspaceID: ws.id, at: deleteDate))
    }

    // MARK: - Audit invariant

    func testSoftDelete_PreservesTeamMembersAndKeys_ForAudit() throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Acme")

        let membersBefore = try db.readTeamMembers(workspaceID: ws.id, includeRemoved: true)
        XCTAssertEqual(membersBefore.count, 1, "expected 1 admin member before soft-delete")

        try svc.softDelete(workspaceID: ws.id, at: deleteDate)

        // Members and keys must NOT be deleted — forever retained for history decryption.
        let membersAfter = try db.readTeamMembers(workspaceID: ws.id, includeRemoved: true)
        XCTAssertEqual(membersAfter.count, 1, "team_members must be preserved after soft-delete (audit invariant)")

        let keyAfter = try db.readActiveTeamKey(workspaceID: ws.id)
        XCTAssertNotNil(keyAfter, "team_keys must be preserved after soft-delete (history decryption)")
    }
}
