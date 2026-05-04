import XCTest
import GRDB
@testable import LeafCore

final class MigrationTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testMigration001CreatesEventsTable() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let tables = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                arguments: [Schema.Events.tableName]
            )
            XCTAssertEqual(tables, [Schema.Events.tableName])
        }
    }

    func testMigration001CreatesBothIndexes() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let indexes = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?",
                arguments: [Schema.Events.tableName]
            )
            XCTAssertTrue(indexes.contains(Schema.Events.indexTs))
            XCTAssertTrue(indexes.contains(Schema.Events.indexBundleTs))
        }
    }

    func testMigration001IsIdempotent() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        // Open + close + reopen should not error on already-applied migration.
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    /// M004 idempotency: повторный open после уже применённой миграции
    /// не пересоздаёт таблицу integrations и не теряет данные.
    func testMigration004IsIdempotent() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db1 = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try db1.upsertIntegration(IntegrationRecord(
            provider: .linear, workspaceID: "ws", workspaceName: "Name",
            accessToken: "tok", refreshToken: nil, expiresAt: nil,
            scope: "read", connectedAt: now, updatedAt: now
        ))

        let db2 = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let loaded = try db2.readIntegration(provider: .linear)
        XCTAssertEqual(loaded?.workspaceID, "ws")
    }

    func testMigrationCreatesAllExpectedColumns() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let columns = try Row.fetchAll(
                rawDB,
                sql: "PRAGMA table_info(\(Schema.Events.tableName))"
            ).compactMap { $0["name"] as String? }

            XCTAssertTrue(columns.contains(Schema.Events.id))
            XCTAssertTrue(columns.contains(Schema.Events.ts))
            XCTAssertTrue(columns.contains(Schema.Events.signalType))
            XCTAssertTrue(columns.contains(Schema.Events.bundleID))
            XCTAssertTrue(columns.contains(Schema.Events.payloadJSON))
        }
    }

    /// Phase 4.7.A M005 — `presence_state` создана с правильной schema.
    func testMigration005CreatesPresenceStateTable() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let tables = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                arguments: [Schema.PresenceState.tableName]
            )
            XCTAssertEqual(tables, [Schema.PresenceState.tableName])

            let columns = try Row.fetchAll(
                rawDB,
                sql: "PRAGMA table_info(\(Schema.PresenceState.tableName))"
            )
            let byName = Dictionary(uniqueKeysWithValues: columns.compactMap { row -> (String, Row)? in
                guard let name = row["name"] as String? else { return nil }
                return (name, row)
            })

            // provider — primary key, NOT NULL.
            let provider = try XCTUnwrap(byName[Schema.PresenceState.provider])
            XCTAssertEqual(provider["pk"] as Int?, 1)
            XCTAssertEqual(provider["notnull"] as Int?, 1)

            // state_json — NOT NULL, default '{}'.
            let stateJSON = try XCTUnwrap(byName[Schema.PresenceState.stateJSON])
            XCTAssertEqual(stateJSON["notnull"] as Int?, 1)

            // derived_mode — nullable (всегда NULL в Phase 4.7).
            let derivedMode = try XCTUnwrap(byName[Schema.PresenceState.derivedMode])
            XCTAssertEqual(derivedMode["notnull"] as Int?, 0)

            // updated_at_ms — NOT NULL.
            let updatedAt = try XCTUnwrap(byName[Schema.PresenceState.updatedAtMs])
            XCTAssertEqual(updatedAt["notnull"] as Int?, 1)
        }
    }

    /// M005 idempotency — повторный open после applied миграции не падает.
    func testMigration005IsIdempotent() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    /// M005 — fresh DB → presence_state пустой (writes идут в Track B).
    func testPresenceStateEmptyAfterMigration() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let count = try Int.fetchOne(
                rawDB,
                sql: "SELECT count(*) FROM \(Schema.PresenceState.tableName)"
            )
            XCTAssertEqual(count, 0)
        }
    }

    // MARK: - Phase 5.1.A — Step 1 sanity (Schema constants + TeamMemberRole)

    /// Phase 5.1.A — Schema namespaces для team-crypto tables присутствуют
    /// и держат ожидаемые SQL identifier'ы. Sanity для Step 1 (до миграций).
    func testPhase51ASchemaConstantsAreDeclared() throws {
        XCTAssertEqual(Schema.Org.tableName, "org")
        XCTAssertEqual(Schema.Org.id, "id")
        XCTAssertEqual(Schema.Org.createdByMemberID, "created_by_member_id")

        XCTAssertEqual(Schema.TeamMembers.tableName, "team_members")
        XCTAssertEqual(Schema.TeamMembers.pubkeyHex, "pubkey_hex")
        XCTAssertEqual(Schema.TeamMembers.removedAtMs, "removed_at_ms")
        XCTAssertEqual(Schema.TeamMembers.indexOrgActive, "team_members_org_active")

        XCTAssertEqual(Schema.TeamKeys.tableName, "team_keys")
        XCTAssertEqual(Schema.TeamKeys.deprecatedAtMs, "deprecated_at_ms")
        XCTAssertEqual(Schema.TeamKeys.indexActive, "team_keys_active")
    }

    /// `TeamMemberRole` rawValue — single source of truth для team_members.role.
    func testTeamMemberRoleRawValuesAreStable() throws {
        XCTAssertEqual(TeamMemberRole.admin.rawValue, "admin")
        XCTAssertEqual(TeamMemberRole.member.rawValue, "member")
        XCTAssertEqual(Set(TeamMemberRole.allCases.map(\.rawValue)), ["admin", "member"])
    }

    // MARK: - Phase 5.1.A — Step 2 (M006 org)

    /// M006 — `org` table создана с правильными столбцами.
    func testMigration006CreatesOrgTable() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let tables = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                arguments: [Schema.Org.tableName]
            )
            XCTAssertEqual(tables, [Schema.Org.tableName])

            let columns = try Row.fetchAll(
                rawDB,
                sql: "PRAGMA table_info(\(Schema.Org.tableName))"
            ).compactMap { $0["name"] as String? }

            XCTAssertEqual(
                Set(columns),
                Set([
                    Schema.Org.id,
                    Schema.Org.name,
                    Schema.Org.createdAtMs,
                    Schema.Org.createdByMemberID
                ])
            )
        }
    }

    /// M006 — `org.id` PK NOT NULL.
    func testMigration006OrgPrimaryKeyIsId() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let columns = try Row.fetchAll(
                rawDB,
                sql: "PRAGMA table_info(\(Schema.Org.tableName))"
            )
            let byName = Dictionary(uniqueKeysWithValues: columns.compactMap { row -> (String, Row)? in
                guard let name = row["name"] as String? else { return nil }
                return (name, row)
            })

            let id = try XCTUnwrap(byName[Schema.Org.id])
            XCTAssertEqual(id["pk"] as Int?, 1)
            XCTAssertEqual(id["notnull"] as Int?, 1)

            // Остальные — NOT NULL без PK.
            for col in [Schema.Org.name, Schema.Org.createdAtMs, Schema.Org.createdByMemberID] {
                let row = try XCTUnwrap(byName[col])
                XCTAssertEqual(row["pk"] as Int?, 0, "column \(col) не должен быть PK")
                XCTAssertEqual(row["notnull"] as Int?, 1, "column \(col) должен быть NOT NULL")
            }
        }
    }

    // MARK: - Phase 5.1.A — Step 3 (M007 team_members)

    /// M007 — `team_members` table создана с правильными столбцами.
    /// `removed_at_ms` nullable, остальные NOT NULL.
    func testMigration007CreatesTeamMembersTable() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let tables = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                arguments: [Schema.TeamMembers.tableName]
            )
            XCTAssertEqual(tables, [Schema.TeamMembers.tableName])

            let columns = try Row.fetchAll(
                rawDB,
                sql: "PRAGMA table_info(\(Schema.TeamMembers.tableName))"
            )
            let byName = Dictionary(uniqueKeysWithValues: columns.compactMap { row -> (String, Row)? in
                guard let name = row["name"] as String? else { return nil }
                return (name, row)
            })

            XCTAssertEqual(
                Set(byName.keys),
                Set([
                    Schema.TeamMembers.id,
                    Schema.TeamMembers.orgID,
                    Schema.TeamMembers.role,
                    Schema.TeamMembers.pubkeyHex,
                    Schema.TeamMembers.displayName,
                    Schema.TeamMembers.addedAtMs,
                    Schema.TeamMembers.removedAtMs
                ])
            )

            // PK на id.
            let id = try XCTUnwrap(byName[Schema.TeamMembers.id])
            XCTAssertEqual(id["pk"] as Int?, 1)
            XCTAssertEqual(id["notnull"] as Int?, 1)

            // Всё кроме removed_at_ms — NOT NULL.
            for col in [
                Schema.TeamMembers.orgID,
                Schema.TeamMembers.role,
                Schema.TeamMembers.pubkeyHex,
                Schema.TeamMembers.displayName,
                Schema.TeamMembers.addedAtMs
            ] {
                let row = try XCTUnwrap(byName[col])
                XCTAssertEqual(row["notnull"] as Int?, 1, "column \(col) должен быть NOT NULL")
            }

            // removed_at_ms — nullable.
            let removed = try XCTUnwrap(byName[Schema.TeamMembers.removedAtMs])
            XCTAssertEqual(removed["notnull"] as Int?, 0)
        }
    }

    /// M007 — partial index `team_members_org_active` присутствует и фильтрует
    /// по `removed_at_ms IS NULL`.
    func testMigration007CreatesActiveIndex() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let indexes = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?",
                arguments: [Schema.TeamMembers.tableName]
            )
            XCTAssertTrue(
                indexes.contains(Schema.TeamMembers.indexOrgActive),
                "expected index \(Schema.TeamMembers.indexOrgActive); found \(indexes)"
            )

            // Verify partial — sqlite_master.sql содержит WHERE clause.
            let sql = try String.fetchOne(
                rawDB,
                sql: "SELECT sql FROM sqlite_master WHERE type='index' AND name=?",
                arguments: [Schema.TeamMembers.indexOrgActive]
            )
            let unwrapped = try XCTUnwrap(sql)
            XCTAssertTrue(
                unwrapped.uppercased().contains("WHERE"),
                "ожидался partial index с WHERE clause; got: \(unwrapped)"
            )
        }
    }

    // MARK: - Phase 5.1.A — Step 4 (M008 team_keys)

    /// M008 — `team_keys` table создана с правильными столбцами.
    /// `deprecated_at_ms` nullable, остальные NOT NULL.
    func testMigration008CreatesTeamKeysTable() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let tables = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                arguments: [Schema.TeamKeys.tableName]
            )
            XCTAssertEqual(tables, [Schema.TeamKeys.tableName])

            let columns = try Row.fetchAll(
                rawDB,
                sql: "PRAGMA table_info(\(Schema.TeamKeys.tableName))"
            )
            let byName = Dictionary(uniqueKeysWithValues: columns.compactMap { row -> (String, Row)? in
                guard let name = row["name"] as String? else { return nil }
                return (name, row)
            })

            XCTAssertEqual(
                Set(byName.keys),
                Set([
                    Schema.TeamKeys.id,
                    Schema.TeamKeys.generatedAtMs,
                    Schema.TeamKeys.deprecatedAtMs,
                    Schema.TeamKeys.generatedByMemberID
                ])
            )

            let id = try XCTUnwrap(byName[Schema.TeamKeys.id])
            XCTAssertEqual(id["pk"] as Int?, 1)
            XCTAssertEqual(id["notnull"] as Int?, 1)

            for col in [Schema.TeamKeys.generatedAtMs, Schema.TeamKeys.generatedByMemberID] {
                let row = try XCTUnwrap(byName[col])
                XCTAssertEqual(row["notnull"] as Int?, 1, "column \(col) должен быть NOT NULL")
            }

            let deprecated = try XCTUnwrap(byName[Schema.TeamKeys.deprecatedAtMs])
            XCTAssertEqual(deprecated["notnull"] as Int?, 0)
        }
    }

    /// M008 — partial index `team_keys_active` присутствует и фильтрует
    /// по `deprecated_at_ms IS NULL`.
    func testMigration008CreatesActiveIndex() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let indexes = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?",
                arguments: [Schema.TeamKeys.tableName]
            )
            XCTAssertTrue(
                indexes.contains(Schema.TeamKeys.indexActive),
                "expected index \(Schema.TeamKeys.indexActive); found \(indexes)"
            )

            let sql = try String.fetchOne(
                rawDB,
                sql: "SELECT sql FROM sqlite_master WHERE type='index' AND name=?",
                arguments: [Schema.TeamKeys.indexActive]
            )
            let unwrapped = try XCTUnwrap(sql)
            XCTAssertTrue(
                unwrapped.uppercased().contains("WHERE"),
                "ожидался partial index с WHERE clause; got: \(unwrapped)"
            )
        }
    }

    func testPlaintextDetectionRenamesFileAndStartsFresh() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let key = EncryptionOptions(keyProvider: .data(Data(repeating: 0xDD, count: 32)))

        // Arrange: создаём plaintext DB с одним событием.
        do {
            let plain = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: nil)
            try plain.write(RawEvent(signalType: .attention, bundleID: "com.legacy"))
            try plain.checkpointWAL()
        }

        // Sanity — файл plaintext.
        let headerBefore = try (FileHandle(forReadingFrom: dbURL).read(upToCount: 16)) ?? Data()
        XCTAssertEqual(headerBefore, Data("SQLite format 3\0".utf8))

        // Act: reopen с encryption — должен рядом появиться .bak и свежая encrypted DB.
        let encrypted = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: key)

        // Assert: .bak существует и plaintext.
        let backup = dbURL.appendingPathExtension("pre-sqlcipher.bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        let headerBak = try (FileHandle(forReadingFrom: backup).read(upToCount: 16)) ?? Data()
        XCTAssertEqual(headerBak, Data("SQLite format 3\0".utf8))

        // Новая DB encrypted: header не SQLite и пустая.
        try encrypted.checkpointWAL()
        let headerNew = try (FileHandle(forReadingFrom: dbURL).read(upToCount: 16)) ?? Data()
        XCTAssertNotEqual(headerNew, Data("SQLite format 3\0".utf8))
        let range = DateInterval(start: .distantPast, duration: 86_400_000)
        XCTAssertEqual(try encrypted.eventCount(in: range), 0)
    }
}
