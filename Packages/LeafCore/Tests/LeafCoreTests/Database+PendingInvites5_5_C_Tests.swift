// Phase 5.5.C — Database public wrappers over PendingInvitesStore. Mirror the
// 5.5.A/5.5.B wrapper test pattern: open writer Database, exercise wrapper, verify
// state via existing PendingInvitesStore raw API or other wrappers.

import GRDB
import XCTest

@testable import LeafCore

final class DatabasePendingInvites5_5_C_Tests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-pending-invites-db-5-5-C-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func openWriter() throws -> LeafCore.Database {
        try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    private func sample(
        token: String,
        createdAtMs: Int64 = 1_700_000_000_000,
        status: PendingInviteStatus = .pending
    ) -> PendingInvite {
        PendingInvite(
            token: token,
            otp: "123456",
            inviteePubkeyHex: String(repeating: "a", count: 64),
            inviteeDisplayNameHint: nil,
            createdAtMs: createdAtMs,
            expiresAtMs: createdAtMs + 24 * 60 * 60 * 1000,
            status: status,
            lastPolledAtMs: nil
        )
    }

    // MARK: - readAllPendingInvites

    func testReadAllPendingInvitesFiltersConsumed() throws {
        let db = try openWriter()
        try db.insertPendingInvite(sample(token: "t1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", status: .pending))
        try db.insertPendingInvite(sample(token: "t2aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", status: .revoked))
        try db.insertPendingInvite(sample(token: "t3aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", status: .consumed))
        try db.insertPendingInvite(sample(token: "t4aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", status: .expired))

        let visible = try db.readAllPendingInvites()
        let tokens = Set(visible.map(\.token))
        XCTAssertEqual(tokens.count, 3, "consumed row excluded")
        XCTAssertFalse(tokens.contains("t3aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
    }

    func testReadAllPendingInvitesOrdersByCreatedAtDesc() throws {
        let db = try openWriter()
        try db.insertPendingInvite(sample(token: "t1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", createdAtMs: 1_000))
        try db.insertPendingInvite(sample(token: "t2aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", createdAtMs: 3_000))
        try db.insertPendingInvite(sample(token: "t3aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", createdAtMs: 2_000))

        let rows = try db.readAllPendingInvites()
        XCTAssertEqual(
            rows.map(\.token),
            [
                "t2aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "t3aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "t1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            ])
    }

    // MARK: - readAllPendingInvitesByStatus

    func testReadAllPendingInvitesByStatus() throws {
        let db = try openWriter()
        try db.insertPendingInvite(sample(token: "t1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", status: .pending))
        try db.insertPendingInvite(sample(token: "t2aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", status: .revoked))
        try db.insertPendingInvite(sample(token: "t3aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", status: .pending))

        let pending = try db.readAllPendingInvitesByStatus(.pending)
        XCTAssertEqual(
            Set(pending.map(\.token)),
            [
                "t1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "t3aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            ])
        XCTAssertEqual(try db.readAllPendingInvitesByStatus(.revoked).count, 1)
        XCTAssertEqual(try db.readAllPendingInvitesByStatus(.expired).count, 0)
    }

    // MARK: - sweepExpiredPendingInvites

    func testSweepExpiredPendingInvitesAffectedCount() throws {
        let db = try openWriter()
        let nowMs: Int64 = 1_700_000_000_000
        try db.insertPendingInvite(sample(token: "t1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", createdAtMs: nowMs))
        try db.insertPendingInvite(
            sample(
                token: "t2aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                createdAtMs: nowMs - 48 * 60 * 60 * 1000
            ))

        XCTAssertEqual(try db.sweepExpiredPendingInvites(nowMs: nowMs), 1)
        XCTAssertEqual(try db.sweepExpiredPendingInvites(nowMs: nowMs), 0, "idempotent re-run")
    }

    // MARK: - deletePendingInvite

    func testDeletePendingInviteIdempotent() throws {
        let db = try openWriter()
        try db.insertPendingInvite(sample(token: "t1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))

        try db.deletePendingInvite(token: "t1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertTrue(try db.readAllPendingInvites().isEmpty)

        // Second delete on missing token — silent no-op (no throw).
        XCTAssertNoThrow(try db.deletePendingInvite(token: "t1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        XCTAssertNoThrow(try db.deletePendingInvite(token: "tneverexisted"))
    }

    // MARK: - updatePendingInviteLastPolledAt

    func testUpdatePendingInviteLastPolledAt() throws {
        let db = try openWriter()
        try db.insertPendingInvite(sample(token: "t1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))

        try db.updatePendingInviteLastPolledAt(
            token: "t1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            atMs: 1_700_000_999_999
        )

        let rows = try db.readAllPendingInvites()
        XCTAssertEqual(rows.first?.lastPolledAtMs, 1_700_000_999_999)
    }
}
