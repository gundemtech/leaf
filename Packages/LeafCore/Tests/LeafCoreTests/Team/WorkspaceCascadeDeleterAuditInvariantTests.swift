// Track 5 / S8 / T8 — Audit invariant fence (sec C2).
//
// **CRITICAL**: WorkspaceCascadeDeleter.execute MUST preserve `team_keys`
// and `team_members` rows after wiping cache. The audit invariant exists so
// decryption history remains available for forensic / rejoin scenarios.
// WorkspaceService.softDelete (line ~168) documents the same contract for
// the soft-delete path.
//
// If a future refactor or careless DELETE statement causes a regression
// here, this test class fires before any production data is destroyed.

import XCTest
import CryptoKit
import GRDB
@testable import LeafCore

final class WorkspaceCascadeDeleterAuditInvariantTests: XCTestCase {
    private var tempDir: URL!
    private var keystoreRoot: URL!
    private var dbURL: URL!
    private var db: LeafCore.Database!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-audit-\(UUID().uuidString)")
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

    /// Critical audit invariant — cascade wipe preserves team_keys + team_members.
    /// Seeds an extra peer member (sender) + extra rotation key (history) so
    /// the test passes only if BOTH the seed-by-createWorkspace row and the
    /// extra peer/rotation rows survive — not just a count > 0.
    func testExecute_PreservesTeamKeysAndTeamMembers_ForAudit() async throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Acme")

        // Seed extra peer member (joined later, not the self-admin) and an
        // additional rotation key (key history; deprecated rotation that
        // could still be needed to decrypt old team_events_mirror rows
        // imported before the workspace was abandoned).
        let extraMember = TeamMember(
            id: UUID().uuidString.lowercased(),
            workspaceID: ws.id,
            role: .member,
            pubkeyHex: String(repeating: "ab", count: 32),
            displayName: "Bob",
            addedAt: Date(timeIntervalSince1970: 1_700_001_000),
            removedAt: nil
        )
        try db.insertTeamMember(extraMember)

        let extraKey = TeamKey(
            id: UUID().uuidString.lowercased(),
            workspaceID: ws.id,
            generatedAt: Date(timeIntervalSince1970: 1_700_002_000),
            deprecatedAt: Date(timeIntervalSince1970: 1_700_003_000),
            generatedByMemberID: extraMember.id
        )
        try db.insertTeamKey(extraKey)

        let membersBefore = try db.readTeamMembers(workspaceID: ws.id, includeRemoved: true)
        XCTAssertEqual(membersBefore.count, 2,
                       "expected 2 members (admin self + extra peer) before cascade")

        // Both initial active key + the seeded deprecated extra key should
        // exist before the cascade. We verify the active one explicitly; the
        // extra-key survival is verified post-cascade via direct row count.
        let activeKeyBefore = try db.readActiveTeamKey(workspaceID: ws.id)
        XCTAssertNotNil(activeKeyBefore, "active team key must exist before cascade")

        let teamKeysCountBefore: Int = try db.readSQL { rawDB in
            let r = try Row.fetchOne(rawDB,
                sql: "SELECT COUNT(*) as n FROM \(Schema.TeamKeys.tableName) WHERE \(Schema.TeamKeys.workspaceID) = ?",
                arguments: [ws.id])!
            return r["n"]
        }
        XCTAssertEqual(teamKeysCountBefore, 2,
                       "expected 2 team_keys rows (initial + extra deprecated) before cascade")

        // ---- CASCADE ----
        let deleter = makeDeleter()
        try await deleter.execute(workspaceID: ws.id)

        // CRITICAL: team_members MUST survive cascade.
        let membersAfter = try db.readTeamMembers(workspaceID: ws.id, includeRemoved: true)
        XCTAssertEqual(membersAfter.count, 2,
                       "AUDIT INVARIANT: team_members must be PRESERVED after cascade wipe")
        XCTAssertTrue(membersAfter.contains { $0.pubkeyHex == extraMember.pubkeyHex },
                      "AUDIT INVARIANT: extra peer member row must survive cascade")

        // CRITICAL: team_keys MUST survive cascade.
        let teamKeysCountAfter: Int = try db.readSQL { rawDB in
            let r = try Row.fetchOne(rawDB,
                sql: "SELECT COUNT(*) as n FROM \(Schema.TeamKeys.tableName) WHERE \(Schema.TeamKeys.workspaceID) = ?",
                arguments: [ws.id])!
            return r["n"]
        }
        XCTAssertEqual(teamKeysCountAfter, 2,
                       "AUDIT INVARIANT: team_keys (initial + deprecated) must be PRESERVED after cascade wipe")
    }

    /// Companion fence: the workspace row IS deleted (proves the test isn't
    /// passing because the cascade simply didn't run). This dovetails with
    /// the preservation assertion above — wipe ran, BUT skipped audit tables.
    func testExecute_WipesWorkspaceRow_AsControlForAuditFence() async throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Acme")
        XCTAssertNotNil(try db.readWorkspace(id: ws.id))

        let deleter = makeDeleter()
        try await deleter.execute(workspaceID: ws.id)

        XCTAssertNil(try db.readWorkspace(id: ws.id),
                     "control: workspace row should be deleted (cascade actually ran)")
    }

    /// Companion fence: keystore folder IS wiped (control — cascade actually ran).
    func testExecute_WipesKeystoreFolder_AsControlForAuditFence() async throws {
        let svc = makeService()
        let ws = try svc.createWorkspace(displayName: "Acme")
        let keystoreDir = keystoreRoot
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(ws.id, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keystoreDir.path))

        let deleter = makeDeleter()
        try await deleter.execute(workspaceID: ws.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: keystoreDir.path),
                       "control: keystore folder should be wiped (cascade actually ran)")
    }
}
