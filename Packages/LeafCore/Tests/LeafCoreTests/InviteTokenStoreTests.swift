// M027 — InviteTokenStore CRUD test coverage.

import XCTest
import GRDB
@testable import LeafCore

final class InviteTokenStoreTests: XCTestCase {
    private var tempDir: URL!
    private var db: LeafCore.Database!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-invite-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        // Seed workspace.
        try db.writeSQL { rawDB in
            try rawDB.execute(sql: """
                INSERT INTO \(Schema.Workspaces.tableName)
                    (\(Schema.Workspaces.id), \(Schema.Workspaces.name),
                     \(Schema.Workspaces.createdAtMs), \(Schema.Workspaces.createdByMemberID))
                VALUES ('w1', 'TestRoom', 1700000000000, 'm1')
                """)
        }
    }

    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - insert + fetch

    func testInsertAndFetchByCode() throws {
        let token = makeToken(code: "LEAF-A8X7-B3K9-Q2N4", label: "Team kickoff")
        try db.writeSQL { rawDB in
            try InviteTokenStore.insert(token, in: rawDB)
        }
        try db.readSQL { rawDB in
            let fetched = try InviteTokenStore.fetch(code: "LEAF-A8X7-B3K9-Q2N4", in: rawDB)
            XCTAssertNotNil(fetched)
            XCTAssertEqual(fetched?.label, "Team kickoff")
            XCTAssertEqual(fetched?.workspaceID, "w1")
            XCTAssertEqual(fetched?.ttlSeconds, 86400)
            XCTAssertNil(fetched?.maxUses)
            XCTAssertNil(fetched?.deletedAt)
        }
    }

    func testFetch_ReturnsNilForMissingCode() throws {
        try db.readSQL { rawDB in
            let fetched = try InviteTokenStore.fetch(code: "LEAF-MISS-MISS-MISS", in: rawDB)
            XCTAssertNil(fetched)
        }
    }

    // MARK: - listActive

    func testListActive_FiltersDeletedAndExpiredAndExhausted() throws {
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let activeT  = makeToken(code: "LEAF-AAAA-BBBB-CCCC", label: "Active",
                                  expiresAt: now.addingTimeInterval(3600))
        let deletedT = makeToken(code: "LEAF-DDDD-EEEE-FFFF", label: "Deleted",
                                  expiresAt: now.addingTimeInterval(3600),
                                  deletedAt: now)
        let expiredT = makeToken(code: "LEAF-JJJJ-KKKK-MMMM", label: "Expired",
                                  expiresAt: now.addingTimeInterval(-3600))
        let exhaustedT = makeToken(code: "LEAF-NNNN-PPPP-QQQQ", label: "Exhausted",
                                    expiresAt: now.addingTimeInterval(3600),
                                    maxUses: 1, usedCount: 1)
        let neverExpiresT = makeToken(code: "LEAF-RRRR-SSSS-TTTT", label: "Forever",
                                       expiresAt: nil)

        try db.writeSQL { rawDB in
            try InviteTokenStore.insert(activeT,  in: rawDB)
            try InviteTokenStore.insert(deletedT, in: rawDB)
            try InviteTokenStore.insert(expiredT, in: rawDB)
            try InviteTokenStore.insert(exhaustedT, in: rawDB)
            try InviteTokenStore.insert(neverExpiresT, in: rawDB)
        }

        try db.readSQL { rawDB in
            let active = try InviteTokenStore.listActive(workspaceID: "w1", now: now, in: rawDB)
            XCTAssertEqual(active.count, 2, "expected Active + Forever only")
            let labels = Set(active.compactMap(\.label))
            XCTAssertEqual(labels, Set(["Active", "Forever"]))
        }
    }

    func testListActive_OrdersByCreatedAtDescending() throws {
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let older = makeToken(code: "LEAF-AAAA-AAAA-AAAA", label: "Older",
                              createdAt: now.addingTimeInterval(-600),
                              expiresAt: now.addingTimeInterval(3600))
        let newer = makeToken(code: "LEAF-BBBB-BBBB-BBBB", label: "Newer",
                              createdAt: now,
                              expiresAt: now.addingTimeInterval(3600))
        try db.writeSQL { rawDB in
            try InviteTokenStore.insert(older, in: rawDB)
            try InviteTokenStore.insert(newer, in: rawDB)
        }
        try db.readSQL { rawDB in
            let active = try InviteTokenStore.listActive(workspaceID: "w1", now: now, in: rawDB)
            XCTAssertEqual(active.map(\.label), ["Newer", "Older"])
        }
    }

    // MARK: - listAll

    func testListAll_IncludesDeletedAndExpiredForAudit() throws {
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let activeT  = makeToken(code: "LEAF-AAAA-BBBB-CCCC", label: "Active",
                                  expiresAt: now.addingTimeInterval(3600))
        let deletedT = makeToken(code: "LEAF-DDDD-EEEE-FFFF", label: "Deleted",
                                  expiresAt: now.addingTimeInterval(3600),
                                  deletedAt: now)
        try db.writeSQL { rawDB in
            try InviteTokenStore.insert(activeT, in: rawDB)
            try InviteTokenStore.insert(deletedT, in: rawDB)
        }
        try db.readSQL { rawDB in
            let all = try InviteTokenStore.listAll(workspaceID: "w1", in: rawDB)
            XCTAssertEqual(all.count, 2)
        }
    }

    // MARK: - countActive

    func testCountActive_MatchesListActiveLength() throws {
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        try db.writeSQL { rawDB in
            try InviteTokenStore.insert(makeToken(code: "LEAF-AAAA-AAAA-AAAA",
                expiresAt: now.addingTimeInterval(3600)), in: rawDB)
            try InviteTokenStore.insert(makeToken(code: "LEAF-BBBB-BBBB-BBBB",
                expiresAt: now.addingTimeInterval(3600)), in: rawDB)
            try InviteTokenStore.insert(makeToken(code: "LEAF-CCCC-CCCC-CCCC",
                expiresAt: now.addingTimeInterval(3600), deletedAt: now), in: rawDB)
        }
        try db.readSQL { rawDB in
            let count = try InviteTokenStore.countActive(workspaceID: "w1", now: now, in: rawDB)
            XCTAssertEqual(count, 2)
        }
    }

    // MARK: - markDeleted

    func testMarkDeleted_SetsDeletedAt() throws {
        let token = makeToken(code: "LEAF-DDDD-DDDD-DDDD", label: "ToDelete")
        try db.writeSQL { rawDB in
            try InviteTokenStore.insert(token, in: rawDB)
        }
        let deletedAt = Date(timeIntervalSince1970: 1_700_050_000)
        try db.writeSQL { rawDB in
            try InviteTokenStore.markDeleted(code: "LEAF-DDDD-DDDD-DDDD", at: deletedAt, in: rawDB)
        }
        try db.readSQL { rawDB in
            let fetched = try InviteTokenStore.fetch(code: "LEAF-DDDD-DDDD-DDDD", in: rawDB)
            let actualDeletedAt = try XCTUnwrap(fetched?.deletedAt)
            XCTAssertEqual(actualDeletedAt.timeIntervalSince1970, deletedAt.timeIntervalSince1970, accuracy: 1)
        }
    }

    func testMarkDeleted_Idempotent() throws {
        let token = makeToken(code: "LEAF-EEEE-EEEE-EEEE", label: "Twice")
        try db.writeSQL { rawDB in
            try InviteTokenStore.insert(token, in: rawDB)
        }
        let first  = Date(timeIntervalSince1970: 1_700_050_000)
        let second = Date(timeIntervalSince1970: 1_700_060_000)
        try db.writeSQL { rawDB in
            try InviteTokenStore.markDeleted(code: "LEAF-EEEE-EEEE-EEEE", at: first, in: rawDB)
            try InviteTokenStore.markDeleted(code: "LEAF-EEEE-EEEE-EEEE", at: second, in: rawDB)
        }
        try db.readSQL { rawDB in
            let fetched = try InviteTokenStore.fetch(code: "LEAF-EEEE-EEEE-EEEE", in: rawDB)
            let actualDeletedAt = try XCTUnwrap(fetched?.deletedAt)
            XCTAssertEqual(actualDeletedAt.timeIntervalSince1970, second.timeIntervalSince1970, accuracy: 1)
        }
    }

    // MARK: - upsert

    func testUpsert_OverridesMutableColumnsOnPKConflict() throws {
        let original = makeToken(code: "LEAF-FFFF-FFFF-FFFF", label: "Original", usedCount: 0)
        try db.writeSQL { rawDB in
            try InviteTokenStore.upsert(original, in: rawDB)
        }
        // Upsert: same code, different label + usedCount.
        let updated = makeToken(code: "LEAF-FFFF-FFFF-FFFF", label: "Updated", usedCount: 3)
        try db.writeSQL { rawDB in
            try InviteTokenStore.upsert(updated, in: rawDB)
        }
        try db.readSQL { rawDB in
            let fetched = try InviteTokenStore.fetch(code: "LEAF-FFFF-FFFF-FFFF", in: rawDB)
            XCTAssertEqual(fetched?.label, "Updated")
            XCTAssertEqual(fetched?.usedCount, 3)
        }
    }

    // MARK: - InviteToken.isActive helper

    func testIsActive_Helper() {
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let active = makeToken(code: "LEAF-XXXX-XXXX-XXXX",
                               expiresAt: now.addingTimeInterval(3600))
        XCTAssertTrue(active.isActive(at: now))

        let deleted = makeToken(code: "LEAF-YYYY-YYYY-YYYY",
                                expiresAt: now.addingTimeInterval(3600),
                                deletedAt: now.addingTimeInterval(-10))
        XCTAssertFalse(deleted.isActive(at: now))

        let expired = makeToken(code: "LEAF-ZZZZ-ZZZZ-ZZZZ",
                                expiresAt: now.addingTimeInterval(-1))
        XCTAssertFalse(expired.isActive(at: now))

        let exhausted = makeToken(code: "LEAF-2222-2222-2222",
                                  expiresAt: now.addingTimeInterval(3600),
                                  maxUses: 2, usedCount: 2)
        XCTAssertFalse(exhausted.isActive(at: now))
    }

    func testDisplayLabel_FallbackToUntitledTokenHash() {
        let labeled = makeToken(code: "LEAF-AAAA-BBBB-CCCC", label: "My token")
        XCTAssertEqual(labeled.displayLabel, "My token")

        let unlabeled = makeToken(code: "LEAF-XYZ2-BBBB-CCCC", label: nil)
        XCTAssertEqual(unlabeled.displayLabel, "Untitled token #XYZ2")

        let emptyLabel = makeToken(code: "LEAF-WXYZ-BBBB-CCCC", label: "")
        XCTAssertEqual(emptyLabel.displayLabel, "Untitled token #WXYZ")
    }

    // MARK: - helper

    private func makeToken(
        code: String,
        label: String? = nil,
        ttlSeconds: Int = 86400,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        expiresAt: Date? = Date(timeIntervalSince1970: 1_700_086_400),
        maxUses: Int? = nil,
        usedCount: Int = 0,
        deletedAt: Date? = nil
    ) -> InviteToken {
        InviteToken(
            code: code,
            workspaceID: "w1",
            createdByPubkeyHex: "aa11",
            label: label,
            ttlSeconds: ttlSeconds,
            expiresAt: expiresAt,
            maxUses: maxUses,
            usedCount: usedCount,
            deletedAt: deletedAt,
            createdAt: createdAt
        )
    }
}
