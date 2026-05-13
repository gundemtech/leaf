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
    /// Track-5 S2: post-M019 expectations — `org` → `workspaces`,
    /// `team_members_org_active` → `team_members_workspace_active`.
    func testPhase51ASchemaConstantsAreDeclared() throws {
        XCTAssertEqual(Schema.Workspaces.tableName, "workspaces")
        XCTAssertEqual(Schema.Workspaces.id, "id")
        XCTAssertEqual(Schema.Workspaces.createdByMemberID, "created_by_member_id")
        // Org typealias still resolves to Workspaces — back-compat shim.
        XCTAssertEqual(Schema.Workspaces.tableName, "workspaces")

        XCTAssertEqual(Schema.TeamMembers.tableName, "team_members")
        XCTAssertEqual(Schema.TeamMembers.pubkeyHex, "pubkey_hex")
        XCTAssertEqual(Schema.TeamMembers.removedAtMs, "removed_at_ms")
        XCTAssertEqual(Schema.TeamMembers.indexWorkspaceActive, "team_members_workspace_active")
        // Back-compat alias for indexOrgActive still resolves to the new index name.
        XCTAssertEqual(Schema.TeamMembers.indexWorkspaceActive, "team_members_workspace_active")

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

    /// M006 — `org` table создана с правильными столбцами. Track-5 S2:
    /// after M019 the table is renamed to `workspaces` and gains a
    /// `left_at_ms` column (OQ-T5-2 soft-mark). Asserts post-M019 shape
    /// because `Database.openForWrite` runs the full migrator chain.
    func testMigration006CreatesOrgTable() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let tables = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                arguments: [Schema.Workspaces.tableName]
            )
            XCTAssertEqual(tables, [Schema.Workspaces.tableName])

            let columns = try Row.fetchAll(
                rawDB,
                sql: "PRAGMA table_info(\(Schema.Workspaces.tableName))"
            ).compactMap { $0["name"] as String? }

            XCTAssertEqual(
                Set(columns),
                Set([
                    Schema.Workspaces.id,
                    Schema.Workspaces.name,
                    Schema.Workspaces.createdAtMs,
                    Schema.Workspaces.createdByMemberID,
                    Schema.Workspaces.leftAtMs
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
                sql: "PRAGMA table_info(\(Schema.Workspaces.tableName))"
            )
            let byName = Dictionary(uniqueKeysWithValues: columns.compactMap { row -> (String, Row)? in
                guard let name = row["name"] as String? else { return nil }
                return (name, row)
            })

            let id = try XCTUnwrap(byName[Schema.Workspaces.id])
            XCTAssertEqual(id["pk"] as Int?, 1)
            XCTAssertEqual(id["notnull"] as Int?, 1)

            // Остальные — NOT NULL без PK.
            for col in [Schema.Workspaces.name, Schema.Workspaces.createdAtMs, Schema.Workspaces.createdByMemberID] {
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
                    Schema.TeamMembers.workspaceID,
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
                Schema.TeamMembers.workspaceID,
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
                indexes.contains(Schema.TeamMembers.indexWorkspaceActive),
                "expected index \(Schema.TeamMembers.indexWorkspaceActive); found \(indexes)"
            )

            // Verify partial — sqlite_master.sql содержит WHERE clause.
            let sql = try String.fetchOne(
                rawDB,
                sql: "SELECT sql FROM sqlite_master WHERE type='index' AND name=?",
                arguments: [Schema.TeamMembers.indexWorkspaceActive]
            )
            let unwrapped = try XCTUnwrap(sql)
            let upper = unwrapped.uppercased()
            XCTAssertTrue(upper.contains("WHERE"), "ожидался partial index; got: \(unwrapped)")
            XCTAssertTrue(
                upper.contains(Schema.TeamMembers.removedAtMs.uppercased()),
                "WHERE clause должен фильтровать по \(Schema.TeamMembers.removedAtMs); got: \(unwrapped)"
            )
            XCTAssertTrue(
                upper.contains("IS NULL"),
                "ожидался WHERE ... IS NULL predicate; got: \(unwrapped)"
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
                    Schema.TeamKeys.workspaceID,
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
            let upper = unwrapped.uppercased()
            XCTAssertTrue(upper.contains("WHERE"), "ожидался partial index; got: \(unwrapped)")
            XCTAssertTrue(
                upper.contains(Schema.TeamKeys.deprecatedAtMs.uppercased()),
                "WHERE clause должен фильтровать по \(Schema.TeamKeys.deprecatedAtMs); got: \(unwrapped)"
            )
            XCTAssertTrue(
                upper.contains("IS NULL"),
                "ожидался WHERE ... IS NULL predicate; got: \(unwrapped)"
            )
        }
    }

    // MARK: - Phase 5.1.A — Step 5 (idempotency + coexistence)

    /// M006/M007/M008 — повторный open после applied миграций не падает
    /// и не пересоздаёт таблицы. Mirrors testMigration001IsIdempotent.
    func testMigration006To008AreIdempotent() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    /// Sanity — после полного open видим все application tables в `sqlite_master`,
    /// то есть migration registration order не ломает existing tables.
    /// Phase 5.5.A добавляет `pending_invites` (M010).
    /// Phase Track-1 D2 добавляет `events_fts` (M012) — FTS5 internal shadow tables
    /// (`events_fts_data`/`_idx`/`_docsize`/`_config`) исключаются явно по имени,
    /// чтобы load-bearing sidecar `events_fts_meta` не прятался под wildcard.
    /// Phase Track-1 D2 добавляет `event_links` (M013).
    func testMigration006To010CoexistWithEarlier() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let tables = try Set(String.fetchAll(
                rawDB,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type='table'
                      AND name NOT LIKE 'sqlite_%'
                      AND name <> 'grdb_migrations'
                      AND name NOT IN ('events_fts_data', 'events_fts_idx', 'events_fts_docsize', 'events_fts_config')
                    """
            ))
            let expected: Set<String> = [
                Schema.Events.tableName,
                Schema.CollectorOffsets.tableName,
                Schema.WatchedFolders.tableName,
                Schema.Integrations.tableName,
                Schema.PresenceState.tableName,
                Schema.Workspaces.tableName,
                Schema.TeamMembers.tableName,
                Schema.TeamKeys.tableName,
                Schema.RotationOutbox.tableName,
                Schema.PendingInvites.tableName,
                Schema.EventsFTS.tableName,
                Schema.EventsFTSMeta.tableName,
                Schema.EventLinks.tableName,
                Schema.Decisions.tableName,
                Schema.OpenQuestions.tableName,
                Schema.Blockers.tableName,
                Schema.WhereStoppedLog.tableName,
                Schema.DetectorOffsets.tableName,
                Schema.ProviderSnapshots.tableName,
                Schema.IntensityAggregates.tableName
            ]
            XCTAssertEqual(tables, expected)
        }
    }

    /// Phase 5.1.A — таблицы создаются пустыми; первые rows будут вставлены
    /// в Phase 5.1.D `OrgService.createPersonalOrg`. Sanity для substrate.
    func testPhase51ATablesEmptyAfterMigration() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            for table in [Schema.Workspaces.tableName, Schema.TeamMembers.tableName, Schema.TeamKeys.tableName] {
                let count = try Int.fetchOne(rawDB, sql: "SELECT count(*) FROM \(table)")
                XCTAssertEqual(count, 0, "expected \(table) пустой после fresh migration")
            }
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
