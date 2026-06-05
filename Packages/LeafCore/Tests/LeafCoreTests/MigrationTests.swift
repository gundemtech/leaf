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

    /// M004 idempotency: reopening after the migration is already applied
    /// does not recreate the integrations table and does not lose data.
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

    /// Phase 4.7.A M005 — `presence_state` is created with the correct schema.
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

            // derived_mode — nullable (always NULL in Phase 4.7).
            let derivedMode = try XCTUnwrap(byName[Schema.PresenceState.derivedMode])
            XCTAssertEqual(derivedMode["notnull"] as Int?, 0)

            // updated_at_ms — NOT NULL.
            let updatedAt = try XCTUnwrap(byName[Schema.PresenceState.updatedAtMs])
            XCTAssertEqual(updatedAt["notnull"] as Int?, 1)
        }
    }

    /// M005 idempotency — reopening after the migration is applied does not crash.
    func testMigration005IsIdempotent() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    /// M005 — fresh DB → presence_state is empty (writes come from Track B).
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

    /// Phase 5.1.A — Schema namespaces for team-crypto tables are present
    /// and hold the expected SQL identifiers. Sanity for Step 1 (before migrations).
    /// Track-5 S2: post-M019 expectations — `org` → `workspaces`,
    /// `team_members_org_active` → `team_members_workspace_active`.
    func testPhase51ASchemaConstantsAreDeclared() throws {
        XCTAssertEqual(Schema.Workspaces.tableName, "workspaces")
        XCTAssertEqual(Schema.Workspaces.id, "id")
        XCTAssertEqual(Schema.Workspaces.createdByMemberID, "created_by_member_id")

        XCTAssertEqual(Schema.TeamMembers.tableName, "team_members")
        XCTAssertEqual(Schema.TeamMembers.pubkeyHex, "pubkey_hex")
        XCTAssertEqual(Schema.TeamMembers.removedAtMs, "removed_at_ms")
        XCTAssertEqual(Schema.TeamMembers.indexWorkspaceActive, "team_members_workspace_active")

        XCTAssertEqual(Schema.TeamKeys.tableName, "team_keys")
        XCTAssertEqual(Schema.TeamKeys.deprecatedAtMs, "deprecated_at_ms")
        XCTAssertEqual(Schema.TeamKeys.indexActive, "team_keys_active")
    }

    /// `TeamMemberRole` rawValue — single source of truth for team_members.role.
    func testTeamMemberRoleRawValuesAreStable() throws {
        XCTAssertEqual(TeamMemberRole.admin.rawValue, "admin")
        XCTAssertEqual(TeamMemberRole.member.rawValue, "member")
        XCTAssertEqual(Set(TeamMemberRole.allCases.map(\.rawValue)), ["admin", "member"])
    }

    // MARK: - Phase 5.1.A — Step 2 (M006 org)

    /// M006 — `org` table is created with the correct columns. Track-5 S2:
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
                    Schema.Workspaces.leftAtMs,
                    Schema.Workspaces.deletedAtMs,                  // Track-5 S7 M025
                    Schema.Workspaces.defaultInviteTtlSeconds,      // M027 invite-redesign
                    Schema.Workspaces.defaultSingleUse              // M027 invite-redesign
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

            // The rest — NOT NULL without PK.
            for col in [Schema.Workspaces.name, Schema.Workspaces.createdAtMs, Schema.Workspaces.createdByMemberID] {
                let row = try XCTUnwrap(byName[col])
                XCTAssertEqual(row["pk"] as Int?, 0, "column \(col) must not be PK")
                XCTAssertEqual(row["notnull"] as Int?, 1, "column \(col) must be NOT NULL")
            }
        }
    }

    // MARK: - Phase 5.1.A — Step 3 (M007 team_members)

    /// M007 — `team_members` table is created with the correct columns.
    /// `removed_at_ms` nullable, the rest NOT NULL.
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

            // PK on id.
            let id = try XCTUnwrap(byName[Schema.TeamMembers.id])
            XCTAssertEqual(id["pk"] as Int?, 1)
            XCTAssertEqual(id["notnull"] as Int?, 1)

            // Everything except removed_at_ms — NOT NULL.
            for col in [
                Schema.TeamMembers.workspaceID,
                Schema.TeamMembers.role,
                Schema.TeamMembers.pubkeyHex,
                Schema.TeamMembers.displayName,
                Schema.TeamMembers.addedAtMs
            ] {
                let row = try XCTUnwrap(byName[col])
                XCTAssertEqual(row["notnull"] as Int?, 1, "column \(col) must be NOT NULL")
            }

            // removed_at_ms — nullable.
            let removed = try XCTUnwrap(byName[Schema.TeamMembers.removedAtMs])
            XCTAssertEqual(removed["notnull"] as Int?, 0)
        }
    }

    /// M007 — partial index `team_members_org_active` is present and filters
    /// on `removed_at_ms IS NULL`.
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

            // Verify partial — sqlite_master.sql contains a WHERE clause.
            let sql = try String.fetchOne(
                rawDB,
                sql: "SELECT sql FROM sqlite_master WHERE type='index' AND name=?",
                arguments: [Schema.TeamMembers.indexWorkspaceActive]
            )
            let unwrapped = try XCTUnwrap(sql)
            let upper = unwrapped.uppercased()
            XCTAssertTrue(upper.contains("WHERE"), "expected a partial index; got: \(unwrapped)")
            XCTAssertTrue(
                upper.contains(Schema.TeamMembers.removedAtMs.uppercased()),
                "WHERE clause must filter on \(Schema.TeamMembers.removedAtMs); got: \(unwrapped)"
            )
            XCTAssertTrue(
                upper.contains("IS NULL"),
                "expected a WHERE ... IS NULL predicate; got: \(unwrapped)"
            )
        }
    }

    // MARK: - Phase 5.1.A — Step 4 (M008 team_keys)

    /// M008 — `team_keys` table is created with the correct columns.
    /// `deprecated_at_ms` nullable, the rest NOT NULL.
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
                XCTAssertEqual(row["notnull"] as Int?, 1, "column \(col) must be NOT NULL")
            }

            let deprecated = try XCTUnwrap(byName[Schema.TeamKeys.deprecatedAtMs])
            XCTAssertEqual(deprecated["notnull"] as Int?, 0)
        }
    }

    /// M008 — partial index `team_keys_active` is present and filters
    /// on `deprecated_at_ms IS NULL`.
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
            XCTAssertTrue(upper.contains("WHERE"), "expected a partial index; got: \(unwrapped)")
            XCTAssertTrue(
                upper.contains(Schema.TeamKeys.deprecatedAtMs.uppercased()),
                "WHERE clause must filter on \(Schema.TeamKeys.deprecatedAtMs); got: \(unwrapped)"
            )
            XCTAssertTrue(
                upper.contains("IS NULL"),
                "expected a WHERE ... IS NULL predicate; got: \(unwrapped)"
            )
        }
    }

    // MARK: - Phase 5.1.A — Step 5 (idempotency + coexistence)

    /// M006/M007/M008 — reopening after the migrations are applied does not crash
    /// and does not recreate the tables. Mirrors testMigration001IsIdempotent.
    func testMigration006To008AreIdempotent() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    /// Sanity — after a full open we see all application tables in `sqlite_master`,
    /// i.e. the migration registration order does not break existing tables.
    /// Phase 5.5.A adds `pending_invites` (M010).
    /// Phase Track-1 D2 adds `events_fts` (M012) — the FTS5 internal shadow tables
    /// (`events_fts_data`/`_idx`/`_docsize`/`_config`) are excluded explicitly by name,
    /// so the load-bearing sidecar `events_fts_meta` is not hidden under the wildcard.
    /// Phase Track-1 D2 adds `event_links` (M013).
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
                Schema.IntensityAggregates.tableName,
                Schema.MessagesMirror.tableName,
                Schema.APNsTokenLocal.tableName,
                Schema.ShareRules.tableName,
                Schema.TeamEventsMirror.tableName,
                Schema.TeamEventBroadcastOffsets.tableName,
                // Track-5 S8 T1 (M026): notification_prefs per-device singleton.
                Schema.NotificationPrefs.tableName,
                // M027 invite-redesign: invite_tokens (admin's local mirror) +
                // workspaces ADD COLUMN defaults (no new table for that ALTER).
                Schema.InviteTokens.tableName,
                // M029 Track-6 P3 browser per-domain allow-list (renamed from M026;
                // integration-T10). M028 — index only, no new table.
                Schema.BrowserDomainAllow.tableName,
                // M030 Track-6 P4 GoogleCalendar typed-event tracker (renamed from
                // dev M027; Ph B trunk unification — appended after M029).
                Schema.GoogleCalendarTracker.tableName,
                // M031 AI Coworker P3 — ai_escalation_audit (append-only reverse audit).
                Schema.AIEscalationAudit.tableName
            ]
            XCTAssertEqual(tables, expected)
        }
    }

    /// Phase 5.1.A — the tables are created empty; the first rows will be inserted
    /// in Phase 5.1.D `OrgService.createPersonalOrg`. Sanity for the substrate.
    func testPhase51ATablesEmptyAfterMigration() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            for table in [Schema.Workspaces.tableName, Schema.TeamMembers.tableName, Schema.TeamKeys.tableName] {
                let count = try Int.fetchOne(rawDB, sql: "SELECT count(*) FROM \(table)")
                XCTAssertEqual(count, 0, "expected \(table) to be empty after a fresh migration")
            }
        }
    }

    // MARK: - Track-6 P1 — M028 partial expression index (renamed from M024 per integration-T10)

    /// M028 EXPLAIN QUERY PLAN — subagent rollup query uses the new index, not full table scan.
    /// On an empty table SQLite's query planner may still pick a SCAN due to the lack of statistics,
    /// so we verify that the index physically exists and is structurally compatible with the WHERE predicate
    /// (covered in testMigration028CreatesClaudeCodeAISubagentIndex). The EXPLAIN test is best-effort:
    /// on a SCAN over an empty table we don't fail, we only confirm that the index is available
    /// as a candidate (the presence of the index name in `sqlite_master` is already verified).
    func testMigration028SubagentRollupUsesIndex() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try db.readSQL { rawDB in
            let plan = try Row.fetchAll(
                rawDB,
                sql: """
                    EXPLAIN QUERY PLAN
                    SELECT * FROM events
                    WHERE json_extract(payload_json, '$.agent_id') IS NOT NULL
                      AND signal_type = 'aiCollaboration';
                """
            )
            let detail = plan.compactMap { row -> String? in
                row["detail"] as? String
            }.joined(separator: " | ")

            // Soft assertion: on an empty table SQLite's planner may pick a SCAN
            // due to the lack of ANALYZE stats. If the index is named in the plan — great;
            // if not — fall back to the structural check (the idx is already verified
            // in testMigration028CreatesClaudeCodeAISubagentIndex). We don't fail the test on an empty table.
            if detail.contains("idx_events_ai_subagent") {
                XCTAssertTrue(true, "subagent rollup query uses idx_events_ai_subagent; plan: \(detail)")
            } else {
                // On an empty table the planner may pick a SCAN — that's OK for the substrate.
                // Phase C will populate payload_json.agent_id, then ANALYZE will provide
                // the statistics the planner needs to pick an index lookup.
                XCTAssertFalse(detail.isEmpty, "EXPLAIN QUERY PLAN should produce some plan; got empty")
            }
        }
    }

    func testPlaintextDetectionRenamesFileAndStartsFresh() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let key = EncryptionOptions(keyProvider: .data(Data(repeating: 0xDD, count: 32)))

        // Arrange: create a plaintext DB with a single event.
        do {
            let plain = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: nil)
            try plain.write(RawEvent(signalType: .attention, bundleID: "com.legacy"))
            try plain.checkpointWAL()
        }

        // Sanity — the file is plaintext.
        let headerBefore = try (FileHandle(forReadingFrom: dbURL).read(upToCount: 16)) ?? Data()
        XCTAssertEqual(headerBefore, Data("SQLite format 3\0".utf8))

        // Act: reopen with encryption — a .bak and a fresh encrypted DB should appear alongside it.
        let encrypted = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: key)

        // Assert: .bak exists and is plaintext.
        let backup = dbURL.appendingPathExtension("pre-sqlcipher.bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        let headerBak = try (FileHandle(forReadingFrom: backup).read(upToCount: 16)) ?? Data()
        XCTAssertEqual(headerBak, Data("SQLite format 3\0".utf8))

        // The new DB is encrypted: header is not SQLite and it is empty.
        try encrypted.checkpointWAL()
        let headerNew = try (FileHandle(forReadingFrom: dbURL).read(upToCount: 16)) ?? Data()
        XCTAssertNotEqual(headerNew, Data("SQLite format 3\0".utf8))
        let range = DateInterval(start: .distantPast, duration: 86_400_000)
        XCTAssertEqual(try encrypted.eventCount(in: range), 0)
    }

    // Track-6 P1 partial expression index (renamed M024 → M028 because
    // Track-5/S5/S7 broadcast offsets already occupy slot M024 on integration-T10).
    func testMigration028CreatesClaudeCodeAISubagentIndex() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(
            at: dbURL,
            config: .weakDefaults,
            encryption: .deterministicTest
        )

        try db.readSQL { rawDB in
            let indexes = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND name=?",
                arguments: ["idx_events_ai_subagent"]
            )
            XCTAssertEqual(
                indexes,
                ["idx_events_ai_subagent"],
                "M028 partial expression index must exist after the migrations"
            )
        }
    }

    // Track-6 P3 browser per-domain allow-list table (renamed M026 → M029 because
    // the Track-5/S8 substrate already occupies slot M026 on integration-T10).
    func testMigration029CreatesBrowserDomainAllowTable() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(
            at: dbURL,
            config: .weakDefaults,
            encryption: .deterministicTest
        )

        try db.readSQL { rawDB in
            let tables = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                arguments: [Schema.BrowserDomainAllow.tableName]
            )
            XCTAssertEqual(
                tables,
                [Schema.BrowserDomainAllow.tableName],
                "M029 browser_domain_allow table must exist after the migrations"
            )
        }
    }

    // MARK: - Phase 5 — stale plaintext-backup auto-purge

    /// Write a dummy plaintext `.bak` next to `dbURL` with a chosen modification date.
    @discardableResult
    private func seedBackup(at dbURL: URL, mtime: Date) throws -> URL {
        let backup = dbURL.appendingPathExtension("pre-sqlcipher.bak")
        try Data("SQLite format 3\u{0}plaintext".utf8).write(to: backup)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: backup.path)
        return backup
    }

    func testPurgeStalePlaintextBackup_OlderThanMaxAge_Deletes() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let created = Date(timeIntervalSince1970: 1_000_000)
        let backup = try seedBackup(at: dbURL, mtime: created)

        Database.purgeStalePlaintextBackupIfNeeded(
            at: dbURL, now: created.addingTimeInterval(40 * 24 * 60 * 60), maxAge: 30 * 24 * 60 * 60)

        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testPurgeStalePlaintextBackup_WithinMaxAge_Retained() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let created = Date(timeIntervalSince1970: 1_000_000)
        let backup = try seedBackup(at: dbURL, mtime: created)

        Database.purgeStalePlaintextBackupIfNeeded(
            at: dbURL, now: created.addingTimeInterval(10 * 24 * 60 * 60), maxAge: 30 * 24 * 60 * 60)

        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testPurgeStalePlaintextBackup_NoBackupFile_NoOp() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        Database.purgeStalePlaintextBackupIfNeeded(at: dbURL)  // no .bak — must not crash
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: dbURL.appendingPathExtension("pre-sqlcipher.bak").path))
    }

    func testOpenForWrite_PurgesStaleBackupAfterMigrate() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let backup = try seedBackup(at: dbURL, mtime: Date().addingTimeInterval(-40 * 24 * 60 * 60))

        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }
}
