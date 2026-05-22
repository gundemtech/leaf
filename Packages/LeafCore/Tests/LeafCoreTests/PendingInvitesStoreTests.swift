// Phase 5.5.A — PendingInvitesStore CRUD: insert / read / readAll / updateStatus
// / updateLastPolledAt / delete. Mirror PresenceStateWriter pattern (static methods
// taking GRDB.Database handle; caller wraps in pool.write block).

import XCTest
import GRDB
@testable import LeafCore

final class PendingInvitesStoreTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-pending-invites-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func sample(
        token: String = "tok-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        workspaceID: String = "wkspc_test",
        otp: String = "123456",
        createdAtMs: Int64 = 1_700_000_000_000,
        status: PendingInviteStatus = .pending
    ) -> PendingInvite {
        PendingInvite(
            token: token,
            workspaceID: workspaceID,
            otp: otp,
            inviteePubkeyHex: String(repeating: "a", count: 64),
            inviteeDisplayNameHint: "Anton",
            createdAtMs: createdAtMs,
            expiresAtMs: createdAtMs + 24 * 60 * 60 * 1000,
            status: status,
            lastPolledAtMs: nil
        )
    }

    private func writeInPool(_ db: LeafCore.Database, _ block: (GRDB.Database) throws -> Void) throws {
        try db.writeSQL(block)
    }

    func testInsertAndRead() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let row = sample()
        try writeInPool(db) { rawDB in
            try PendingInvitesStore.insert(row, in: rawDB)
        }
        try db.readSQL { rawDB in
            let read = try XCTUnwrap(try PendingInvitesStore.read(token: row.token, in: rawDB))
            XCTAssertEqual(read, row)
        }
    }

    func testReadMissingReturnsNil() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try db.readSQL { rawDB in
            XCTAssertNil(try PendingInvitesStore.read(token: "nonexistent", in: rawDB))
        }
    }

    func testInsertDuplicateTokenThrows() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let row = sample()
        try writeInPool(db) { rawDB in
            try PendingInvitesStore.insert(row, in: rawDB)
        }
        XCTAssertThrowsError(try writeInPool(db) { rawDB in
            try PendingInvitesStore.insert(row, in: rawDB)
        })
    }

    func testReadAllUnfiltered() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let r1 = sample(token: "t1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", createdAtMs: 1_000, status: .pending)
        let r2 = sample(token: "t2aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", createdAtMs: 3_000, status: .consumed)
        let r3 = sample(token: "t3aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", createdAtMs: 2_000, status: .pending)
        try writeInPool(db) { rawDB in
            try PendingInvitesStore.insert(r1, in: rawDB)
            try PendingInvitesStore.insert(r2, in: rawDB)
            try PendingInvitesStore.insert(r3, in: rawDB)
        }
        try db.readSQL { rawDB in
            let all = try PendingInvitesStore.readAll(status: nil, in: rawDB)
            // Order: created_at_ms DESC.
            XCTAssertEqual(all.map(\.token), [r2.token, r3.token, r1.token])
        }
    }

    func testReadAllFilteredByStatus() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let r1 = sample(token: "t1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", createdAtMs: 1_000, status: .pending)
        let r2 = sample(token: "t2aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", createdAtMs: 2_000, status: .consumed)
        let r3 = sample(token: "t3aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", createdAtMs: 3_000, status: .pending)
        try writeInPool(db) { rawDB in
            try PendingInvitesStore.insert(r1, in: rawDB)
            try PendingInvitesStore.insert(r2, in: rawDB)
            try PendingInvitesStore.insert(r3, in: rawDB)
        }
        try db.readSQL { rawDB in
            let pending = try PendingInvitesStore.readAll(status: .pending, in: rawDB)
            XCTAssertEqual(Set(pending.map(\.token)), [r1.token, r3.token])
            let consumed = try PendingInvitesStore.readAll(status: .consumed, in: rawDB)
            XCTAssertEqual(consumed.map(\.token), [r2.token])
        }
    }

    func testUpdateStatusPersists() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let row = sample()
        try writeInPool(db) { rawDB in
            try PendingInvitesStore.insert(row, in: rawDB)
            try PendingInvitesStore.updateStatus(token: row.token, status: .consumed, in: rawDB)
        }
        try db.readSQL { rawDB in
            let read = try XCTUnwrap(try PendingInvitesStore.read(token: row.token, in: rawDB))
            XCTAssertEqual(read.status, .consumed)
        }
    }

    func testUpdateLastPolledAtPersists() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let row = sample()
        try writeInPool(db) { rawDB in
            try PendingInvitesStore.insert(row, in: rawDB)
            try PendingInvitesStore.updateLastPolledAt(token: row.token, atMs: 9_999, in: rawDB)
        }
        try db.readSQL { rawDB in
            let read = try XCTUnwrap(try PendingInvitesStore.read(token: row.token, in: rawDB))
            XCTAssertEqual(read.lastPolledAtMs, 9_999)
        }
    }

    func testDelete() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let row = sample()
        try writeInPool(db) { rawDB in
            try PendingInvitesStore.insert(row, in: rawDB)
            try PendingInvitesStore.delete(token: row.token, in: rawDB)
            // Idempotent: re-delete is no-op.
            try PendingInvitesStore.delete(token: row.token, in: rawDB)
            // Delete non-existent — no-op too.
            try PendingInvitesStore.delete(token: "never-existed", in: rawDB)
        }
        try db.readSQL { rawDB in
            XCTAssertNil(try PendingInvitesStore.read(token: row.token, in: rawDB))
        }
    }

    // MARK: - Phase 5.5.C — sweepExpired

    func testSweepExpiredFlipsPendingPastDeadline() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let nowMs: Int64 = 1_700_000_000_000
        let live = sample(token: "t1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", createdAtMs: nowMs)
        let expired = sample(
            token: "t2aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            createdAtMs: nowMs - 48 * 60 * 60 * 1000
        )
        let alreadyRevoked = sample(
            token: "t3aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            createdAtMs: nowMs - 48 * 60 * 60 * 1000,
            status: .revoked
        )
        try writeInPool(db) { rawDB in
            try PendingInvitesStore.insert(live, in: rawDB)
            try PendingInvitesStore.insert(expired, in: rawDB)
            try PendingInvitesStore.insert(alreadyRevoked, in: rawDB)
        }

        try writeInPool(db) { rawDB in
            let affected = try PendingInvitesStore.sweepExpired(nowMs: nowMs, in: rawDB)
            XCTAssertEqual(affected, 1, "Only the past-deadline .pending row flips")
        }

        try db.readSQL { rawDB in
            let liveRow = try XCTUnwrap(try PendingInvitesStore.read(token: live.token, in: rawDB))
            XCTAssertEqual(liveRow.status, .pending)

            let expiredRow = try XCTUnwrap(try PendingInvitesStore.read(token: expired.token, in: rawDB))
            XCTAssertEqual(expiredRow.status, .expired)

            let revokedRow = try XCTUnwrap(try PendingInvitesStore.read(token: alreadyRevoked.token, in: rawDB))
            XCTAssertEqual(revokedRow.status, .revoked, "sweep does not touch non-.pending rows")
        }
    }

    func testSweepExpiredIdempotentSecondRun() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let nowMs: Int64 = 1_700_000_000_000
        let expired = sample(
            token: "t1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            createdAtMs: nowMs - 48 * 60 * 60 * 1000
        )
        try writeInPool(db) { rawDB in
            try PendingInvitesStore.insert(expired, in: rawDB)
        }
        try writeInPool(db) { rawDB in
            _ = try PendingInvitesStore.sweepExpired(nowMs: nowMs, in: rawDB)
        }
        try writeInPool(db) { rawDB in
            let affected = try PendingInvitesStore.sweepExpired(nowMs: nowMs, in: rawDB)
            XCTAssertEqual(affected, 0, "Second sweep finds no .pending past deadline")
        }
    }
}
