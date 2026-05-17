import Foundation
import GRDB
import XCTest

@testable import LeafCore

/// Phase 5.3.D — `rotation_outbox` write-ahead journal helpers
/// (`commitRotation` / `markRotationOutboxPosted` / `readUnpostedRotationOutboxRows`).
final class DatabaseRotationOutboxTests: XCTestCase {

    private var tempDir: URL!
    private var dbURL: URL!
    private var db: LeafCore.Database!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-rotationoutbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
        db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func makeDate(_ epochMs: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(epochMs) / 1000.0)
    }

    private func insertOrgFixture(
        orgID: String = "org1",
        selfMemberID: String = "self-mem",
        priorKeyID: String = "key0"
    ) throws {
        try db.upsertOrg(
            Org(
                id: orgID,
                name: "Test Org",
                createdAt: makeDate(1_700_000_000_000),
                createdByMemberID: selfMemberID
            ))
        try db.insertTeamMember(
            TeamMember(
                id: selfMemberID,
                orgID: orgID,
                role: .admin,
                pubkeyHex: String(repeating: "aa", count: 32),
                displayName: "Self",
                addedAt: makeDate(1_700_000_000_000),
                removedAt: nil
            ))
        try db.insertTeamKey(
            TeamKey(
                id: priorKeyID,
                generatedAt: makeDate(1_700_000_000_000),
                deprecatedAt: nil,
                generatedByMemberID: selfMemberID
            ))
    }

    private func sampleOutboxRow(
        peer: String = String(repeating: "bb", count: 32),
        newKeyID: String = "key1",
        priorKeyID: String = "key0",
        kind: RotationKind = .rotation,
        peerMemberID: String = "peer-mem",
        createdAtMs: Int64 = 1_700_000_001_000,
        postedAtMs: Int64? = nil
    ) -> RotationOutboxRow {
        RotationOutboxRow(
            peerPubkeyHex: peer,
            newKeyID: newKeyID,
            priorKeyID: priorKeyID,
            kind: kind,
            peerMemberID: peerMemberID,
            blob: Data([0x03, 0x01, 0x02]),
            expiresAtMs: 1_700_000_086_400_000,
            createdAtMs: createdAtMs,
            postedAtMs: postedAtMs
        )
    }

    // MARK: - M009 sanity

    func testM009MigrationCreatesRotationOutboxTable() throws {
        // db is already opened via setUp — the migration ran. Verify table exists.
        let count: Int = try db.writeSQL { rawDB in
            try Int.fetchOne(rawDB, sql: "SELECT count(*) FROM \(Schema.RotationOutbox.tableName)") ?? -1
        }
        XCTAssertEqual(count, 0)
    }

    // MARK: - commitRotation

    func testCommitRotation_HappyPath_NewActiveOldDeprecated() throws {
        try insertOrgFixture()
        let newKey = TeamKey(
            id: "key1", generatedAt: makeDate(1_700_000_001_000), deprecatedAt: nil, generatedByMemberID: "self-mem")
        let row = sampleOutboxRow()

        try db.commitRotation(
            newTeamKey: newKey,
            priorTeamKeyID: "key0",
            deprecatedAt: makeDate(1_700_000_001_000),
            removedMemberID: nil,
            removedAt: nil,
            outboxRows: [row]
        )

        XCTAssertEqual(try db.readActiveTeamKey()?.id, "key1")
        let prior = try db.readTeamKey(byID: "key0")
        XCTAssertNotNil(prior?.deprecatedAt)
        let unposted = try db.readUnpostedRotationOutboxRows()
        XCTAssertEqual(unposted.count, 1)
        XCTAssertEqual(unposted.first?.peerPubkeyHex, row.peerPubkeyHex)
    }

    func testCommitRotation_WithRemovedMember_UpdatesAllThreeTables() throws {
        try insertOrgFixture()
        try db.insertTeamMember(
            TeamMember(
                id: "peer-mem", orgID: "org1", role: .member,
                pubkeyHex: String(repeating: "bb", count: 32), displayName: "Peer",
                addedAt: makeDate(1_700_000_000_500), removedAt: nil
            ))
        let newKey = TeamKey(
            id: "key1", generatedAt: makeDate(1_700_000_001_000), deprecatedAt: nil, generatedByMemberID: "self-mem")
        let tombstone = sampleOutboxRow(newKeyID: "key0", priorKeyID: "key0", kind: .tombstone)

        try db.commitRotation(
            newTeamKey: newKey,
            priorTeamKeyID: "key0",
            deprecatedAt: makeDate(1_700_000_001_000),
            removedMemberID: "peer-mem",
            removedAt: makeDate(1_700_000_001_000),
            outboxRows: [tombstone]
        )

        let removedMember = try db.readTeamMembers(orgID: "org1", includeRemoved: true)
            .first(where: { $0.id == "peer-mem" })
        XCTAssertNotNil(removedMember?.removedAt)
        XCTAssertEqual(try db.readActiveTeamKey()?.id, "key1")
    }

    func testCommitRotation_NilNonNilMismatchThrows() throws {
        try insertOrgFixture()
        let newKey = TeamKey(
            id: "key1", generatedAt: makeDate(1_700_000_001_000), deprecatedAt: nil, generatedByMemberID: "self-mem")

        XCTAssertThrowsError(
            try db.commitRotation(
                newTeamKey: newKey,
                priorTeamKeyID: "key0",
                deprecatedAt: makeDate(1_700_000_001_000),
                removedMemberID: "peer-mem",
                removedAt: nil,
                outboxRows: []
            )
        ) { error in
            XCTAssertTrue(matches(error, .invalidPayload))
        }
    }

    func testCommitRotation_FailsWhenPriorTeamKeyMissing() throws {
        try insertOrgFixture()
        let newKey = TeamKey(
            id: "key1", generatedAt: makeDate(1_700_000_001_000), deprecatedAt: nil, generatedByMemberID: "self-mem")

        XCTAssertThrowsError(
            try db.commitRotation(
                newTeamKey: newKey,
                priorTeamKeyID: "missing-id",
                deprecatedAt: makeDate(1_700_000_001_000),
                removedMemberID: nil,
                removedAt: nil,
                outboxRows: []
            )
        ) { XCTAssertTrue(matches($0, .invalidPayload)) }

        XCTAssertNil(try db.readTeamKey(byID: "key1"))  // rollback
    }

    func testCommitRotation_FailsWhenPriorAlreadyDeprecated() throws {
        try insertOrgFixture()
        // Insert a second active key so we can deprecate "key0" without sole-active throw.
        try db.insertTeamKey(
            TeamKey(
                id: "key0b",
                generatedAt: makeDate(1_700_000_000_500),
                deprecatedAt: nil,
                generatedByMemberID: "self-mem"
            ))
        try db.deprecateTeamKey(keyID: "key0", at: makeDate(1_700_000_000_750))

        let newKey = TeamKey(
            id: "key1", generatedAt: makeDate(1_700_000_001_000), deprecatedAt: nil, generatedByMemberID: "self-mem")
        XCTAssertThrowsError(
            try db.commitRotation(
                newTeamKey: newKey,
                priorTeamKeyID: "key0",
                deprecatedAt: makeDate(1_700_000_001_000),
                removedMemberID: nil,
                removedAt: nil,
                outboxRows: []
            )
        ) { XCTAssertTrue(matches($0, .invalidPayload)) }
    }

    func testCommitRotation_FailsWhenRemovedMemberMissing() throws {
        try insertOrgFixture()
        let newKey = TeamKey(
            id: "key1", generatedAt: makeDate(1_700_000_001_000), deprecatedAt: nil, generatedByMemberID: "self-mem")
        XCTAssertThrowsError(
            try db.commitRotation(
                newTeamKey: newKey,
                priorTeamKeyID: "key0",
                deprecatedAt: makeDate(1_700_000_001_000),
                removedMemberID: "ghost-member",
                removedAt: makeDate(1_700_000_001_000),
                outboxRows: []
            )
        ) { XCTAssertTrue(matches($0, .invalidPayload)) }
    }

    func testCommitRotation_FailsWhenRemovedMemberAlreadyRemoved() throws {
        try insertOrgFixture()
        try db.insertTeamMember(
            TeamMember(
                id: "peer-mem", orgID: "org1", role: .member,
                pubkeyHex: String(repeating: "bb", count: 32), displayName: "Peer",
                addedAt: makeDate(1_700_000_000_500), removedAt: nil
            ))
        try db.markTeamMemberRemoved(memberID: "peer-mem", at: makeDate(1_700_000_000_750))

        let newKey = TeamKey(
            id: "key1", generatedAt: makeDate(1_700_000_001_000), deprecatedAt: nil, generatedByMemberID: "self-mem")
        XCTAssertThrowsError(
            try db.commitRotation(
                newTeamKey: newKey,
                priorTeamKeyID: "key0",
                deprecatedAt: makeDate(1_700_000_001_000),
                removedMemberID: "peer-mem",
                removedAt: makeDate(1_700_000_001_000),
                outboxRows: []
            )
        ) { XCTAssertTrue(matches($0, .invalidPayload)) }
    }

    func testCommitRotation_FailsOnDuplicateOutboxRow() throws {
        try insertOrgFixture()
        let newKey = TeamKey(
            id: "key1", generatedAt: makeDate(1_700_000_001_000), deprecatedAt: nil, generatedByMemberID: "self-mem")
        let row = sampleOutboxRow()

        // First commit succeeds
        try db.commitRotation(
            newTeamKey: newKey,
            priorTeamKeyID: "key0",
            deprecatedAt: makeDate(1_700_000_001_000),
            removedMemberID: nil,
            removedAt: nil,
            outboxRows: [row]
        )

        // Second commit reuses outbox row with composite PK (peer, "key1") — collision.
        // newTeamKey="key2" / priorTeamKey="key1" (currently active after first commit).
        let newKey2 = TeamKey(
            id: "key2", generatedAt: makeDate(1_700_000_002_000), deprecatedAt: nil, generatedByMemberID: "self-mem")
        XCTAssertThrowsError(
            try db.commitRotation(
                newTeamKey: newKey2,
                priorTeamKeyID: "key1",
                deprecatedAt: makeDate(1_700_000_002_000),
                removedMemberID: nil,
                removedAt: nil,
                outboxRows: [row]
            )
        )
    }

    // MARK: - markRotationOutboxPosted

    func testMarkRotationOutboxPosted_HappyPath() throws {
        try insertOrgFixture()
        let row = sampleOutboxRow()
        let newKey = TeamKey(
            id: "key1", generatedAt: makeDate(1_700_000_001_000), deprecatedAt: nil, generatedByMemberID: "self-mem")
        try db.commitRotation(
            newTeamKey: newKey, priorTeamKeyID: "key0",
            deprecatedAt: makeDate(1_700_000_001_000),
            removedMemberID: nil, removedAt: nil,
            outboxRows: [row]
        )

        try db.markRotationOutboxPosted(
            peerPubkeyHex: row.peerPubkeyHex,
            newKeyID: row.newKeyID,
            at: makeDate(1_700_000_002_000)
        )

        XCTAssertTrue(try db.readUnpostedRotationOutboxRows().isEmpty)
    }

    func testMarkRotationOutboxPosted_IsIdempotentOnAlreadyPosted() throws {
        try insertOrgFixture()
        let row = sampleOutboxRow()
        let newKey = TeamKey(
            id: "key1", generatedAt: makeDate(1_700_000_001_000), deprecatedAt: nil, generatedByMemberID: "self-mem")
        try db.commitRotation(
            newTeamKey: newKey, priorTeamKeyID: "key0",
            deprecatedAt: makeDate(1_700_000_001_000),
            removedMemberID: nil, removedAt: nil,
            outboxRows: [row]
        )

        try db.markRotationOutboxPosted(
            peerPubkeyHex: row.peerPubkeyHex, newKeyID: row.newKeyID, at: makeDate(1_700_000_002_000))
        // Second mark — silent no-op (already posted, no throw).
        try db.markRotationOutboxPosted(
            peerPubkeyHex: row.peerPubkeyHex, newKeyID: row.newKeyID, at: makeDate(1_700_000_003_000))

        XCTAssertTrue(try db.readUnpostedRotationOutboxRows().isEmpty)
    }

    func testMarkRotationOutboxPosted_OnMissingRowSilent() throws {
        try insertOrgFixture()
        // Call markPosted on non-existent (peer, key) — tolerant for crash-resume race.
        try db.markRotationOutboxPosted(
            peerPubkeyHex: String(repeating: "ff", count: 32),
            newKeyID: "ghost-id",
            at: makeDate(1_700_000_002_000)
        )
        // No assertion needed beyond "did not throw".
    }

    func testMarkRotationOutboxPosted_ReaderModeThrowsDatabaseUnavailable() throws {
        try insertOrgFixture()
        let readerDB = try LeafCore.Database.openForRead(
            at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        XCTAssertThrowsError(
            try readerDB.markRotationOutboxPosted(peerPubkeyHex: "aa", newKeyID: "k1", at: makeDate(1_700_000_002_000))
        ) { XCTAssertTrue(matches($0, .databaseUnavailable)) }
    }

    // MARK: - readUnpostedRotationOutboxRows ordering

    func testReadUnpostedRotationOutboxRows_FiltersAndOrders() throws {
        try insertOrgFixture()
        let earlier = sampleOutboxRow(
            peer: String(repeating: "aa", count: 32),
            createdAtMs: 1_700_000_001_000
        )
        let later = sampleOutboxRow(
            peer: String(repeating: "cc", count: 32),
            createdAtMs: 1_700_000_005_000
        )

        let newKey = TeamKey(
            id: "key1", generatedAt: makeDate(1_700_000_001_000), deprecatedAt: nil, generatedByMemberID: "self-mem")
        try db.commitRotation(
            newTeamKey: newKey, priorTeamKeyID: "key0",
            deprecatedAt: makeDate(1_700_000_001_000),
            removedMemberID: nil, removedAt: nil,
            outboxRows: [earlier, later]
        )

        // Mark `earlier` posted — should be filtered out from unposted.
        try db.markRotationOutboxPosted(
            peerPubkeyHex: earlier.peerPubkeyHex,
            newKeyID: earlier.newKeyID,
            at: makeDate(1_700_000_010_000)
        )

        let result = try db.readUnpostedRotationOutboxRows()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.peerPubkeyHex, later.peerPubkeyHex)
    }

    func testReadUnpostedRotationOutboxRows_OrdersByCreatedAt() throws {
        try insertOrgFixture()
        let row1 = sampleOutboxRow(peer: String(repeating: "aa", count: 32), createdAtMs: 1_700_000_005_000)
        let row2 = sampleOutboxRow(peer: String(repeating: "bb", count: 32), createdAtMs: 1_700_000_001_000)
        let row3 = sampleOutboxRow(peer: String(repeating: "cc", count: 32), createdAtMs: 1_700_000_003_000)

        let newKey = TeamKey(
            id: "key1", generatedAt: makeDate(1_700_000_001_000), deprecatedAt: nil, generatedByMemberID: "self-mem")
        try db.commitRotation(
            newTeamKey: newKey, priorTeamKeyID: "key0",
            deprecatedAt: makeDate(1_700_000_001_000),
            removedMemberID: nil, removedAt: nil,
            outboxRows: [row1, row2, row3]
        )

        let result = try db.readUnpostedRotationOutboxRows()
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].peerPubkeyHex, row2.peerPubkeyHex)  // 1_700_000_001 first
        XCTAssertEqual(result[1].peerPubkeyHex, row3.peerPubkeyHex)  // 1_700_000_003 second
        XCTAssertEqual(result[2].peerPubkeyHex, row1.peerPubkeyHex)  // 1_700_000_005 last
    }

    func testCommitRotation_ReaderModeThrowsDatabaseUnavailable() throws {
        try insertOrgFixture()
        let readerDB = try Database.openForRead(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let newKey = TeamKey(
            id: "key1", generatedAt: makeDate(1_700_000_001_000), deprecatedAt: nil, generatedByMemberID: "self-mem")
        XCTAssertThrowsError(
            try readerDB.commitRotation(
                newTeamKey: newKey,
                priorTeamKeyID: "key0",
                deprecatedAt: makeDate(1_700_000_001_000),
                removedMemberID: nil,
                removedAt: nil,
                outboxRows: []
            )
        ) { XCTAssertTrue(matches($0, .databaseUnavailable)) }
    }
}

// MARK: - Local error matcher

private func matches(_ error: Error, _ expected: LeafError) -> Bool {
    guard let lerr = error as? LeafError else { return false }
    switch (lerr, expected) {
    case (.invalidPayload, .invalidPayload),
        (.databaseUnavailable, .databaseUnavailable):
        return true
    default:
        return false
    }
}
