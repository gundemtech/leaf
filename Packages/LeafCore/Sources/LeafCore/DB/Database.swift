import Foundation
import GRDB
import os

/// GRDB 7.x wrapper с опциональной SQLCipher-шифровкой.
/// Writer (Agent) и Reader (App / MCP) — разные `Database` instance'ы поверх одного файла через WAL.
/// `encryption: nil` на open* → plaintext (CI / unit-тесты). `.some(...)` → SQLCipher-encrypted.
public final class Database: @unchecked Sendable {
    public enum Mode: Sendable { case writer, reader }

    private let pool: DatabasePool
    private let config: DatabaseConfig
    public let mode: Mode

    private init(pool: DatabasePool, config: DatabaseConfig, mode: Mode) {
        self.pool = pool
        self.config = config
        self.mode = mode
    }

    // MARK: - Opening

    public static func openForWrite(
        at url: URL,
        config: DatabaseConfig,
        encryption: EncryptionOptions? = nil
    ) throws -> Database {
        try ensureDirectory(for: url)
        try migrateFromPlaintextIfNeeded(at: url, encryption: encryption)

        var grdbConfig = Configuration()
        grdbConfig.readonly = false
        grdbConfig.busyMode = .timeout(TimeInterval(config.busyTimeoutMs) / 1000.0)
        applyEncryption(encryption, to: &grdbConfig)

        let pool = try DatabasePool(path: url.path, configuration: grdbConfig)

        var migrator = DatabaseMigrator()
        migrator.registerMigration001Events()
        migrator.registerMigration002CollectorOffsets()
        migrator.registerMigration003WatchedFolders()
        migrator.registerMigration004Integrations()
        migrator.registerMigration005PresenceState()
        migrator.registerMigration006Org()
        migrator.registerMigration007TeamMembers()
        migrator.registerMigration008TeamKeys()
        migrator.registerMigration009RotationOutbox()
        migrator.registerMigration010PendingInvites()
        migrator.registerMigration011EventKindIndex()
        migrator.registerMigration012EventsFTS()
        migrator.registerMigration013EventLinks()
        migrator.registerMigration014DetectionTables()
        migrator.registerMigration015ProviderSnapshots()
        try migrator.migrate(pool)

        return Database(pool: pool, config: config, mode: .writer)
    }

    public static func openForRead(
        at url: URL,
        config: DatabaseConfig,
        encryption: EncryptionOptions? = nil
    ) throws -> Database {
        var grdbConfig = Configuration()
        grdbConfig.readonly = true
        grdbConfig.busyMode = .timeout(TimeInterval(config.busyTimeoutMs) / 1000.0)
        applyEncryption(encryption, to: &grdbConfig)

        let pool = try DatabasePool(path: url.path, configuration: grdbConfig)
        return Database(pool: pool, config: config, mode: .reader)
    }

    // MARK: - Writes

    public func write(
        _ event: RawEvent,
        knownLinearPrefixes: Set<String> = [],
        derivers: LinkDerivers = .publicSubstrate
    ) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }

        try pool.write { db in
            _ = try Self.writeEventAndDerived(
                event, knownLinearPrefixes: knownLinearPrefixes, derivers: derivers, in: db
            )
        }
    }

    public func write(
        _ events: [RawEvent],
        knownLinearPrefixes: Set<String> = [],
        derivers: LinkDerivers = .publicSubstrate
    ) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        guard !events.isEmpty else { return }

        try pool.write { db in
            for event in events {
                _ = try Self.writeEventAndDerived(
                    event, knownLinearPrefixes: knownLinearPrefixes, derivers: derivers, in: db
                )
            }
        }
    }

    /// Phase Track-1 D2 — single insertion path used by all three public write
    /// entry-points. Keeps event insert + FTS5 row insert + link derivation
    /// atomic within one `pool.write {}` block. Returns the inserted event id.
    private static func writeEventAndDerived(
        _ event: RawEvent,
        knownLinearPrefixes: Set<String>,
        derivers: LinkDerivers,
        in db: GRDB.Database
    ) throws -> Int64 {
        var record = try EventRecord.make(from: event)
        try record.insert(db)
        guard let eventID = record.id else { throw LeafError.invalidPayload }
        let tsMs = Int64(event.timestamp.timeIntervalSince1970 * 1000)

        try EventsFullTextStore.indexEvent(
            eventID: eventID,
            signalType: event.signalType.rawValue,
            bundleID: event.bundleID,
            payload: event.payload,
            in: db
        )
        try EventLinksStore.deriveLinks(
            eventID: eventID,
            ts: tsMs,
            payload: event.payload,
            knownLinearPrefixes: knownLinearPrefixes,
            derivers: derivers,
            in: db
        )
        return eventID
    }

    // MARK: - Reads

    public func events(in range: DateInterval, bundleID: String? = nil) throws -> [RawEvent] {
        let startMs = Int64(range.start.timeIntervalSince1970 * 1000)
        let endMs = Int64(range.end.timeIntervalSince1970 * 1000)

        let records: [EventRecord] = try pool.read { db in
            var request = EventRecord
                .filter(Column(Schema.Events.ts) >= startMs)
                .filter(Column(Schema.Events.ts) < endMs)
                .order(Column(Schema.Events.ts))

            if let bundleID {
                request = request.filter(Column(Schema.Events.bundleID) == bundleID)
            }

            return try request.fetchAll(db)
        }

        return try records.map { try $0.toRawEvent() }
    }

    public func eventCount(in range: DateInterval) throws -> Int {
        let startMs = Int64(range.start.timeIntervalSince1970 * 1000)
        let endMs = Int64(range.end.timeIntervalSince1970 * 1000)

        return try pool.read { db in
            try EventRecord
                .filter(Column(Schema.Events.ts) >= startMs)
                .filter(Column(Schema.Events.ts) < endMs)
                .fetchCount(db)
        }
    }

    // MARK: - Maintenance

    /// Принудительный `PRAGMA wal_checkpoint(TRUNCATE)`.
    /// При активных reader'ах SQLite может сделать partial checkpoint (advance только
    /// до hwm самого отстающего reader'а) — это штатный graceful degradation, не ошибка.
    /// В этом случае WAL-файл не усохнет до 0, но продолжит контролироваться следующим
    /// успешным checkpoint'ом. Retry / force никакой не нужен.
    public func checkpointWAL() throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.writeWithoutTransaction { db in
            _ = try db.checkpoint(.truncate)
        }
    }

    /// Удаляет до `limit` старейших строк из `events` со `ts < tsMs`.
    /// Возвращает реальное количество удалённых строк (`db.changesCount`).
    /// Используется retention sweep в `MaintenanceScheduler`; вызывается в цикле,
    /// пока `return < limit` — чанк-за-чанком, чтобы не держать writer-транзакцию
    /// дольше `busyTimeoutMs` при миллионных таблицах.
    ///
    /// Subquery-pattern (не `DELETE ... LIMIT ?`): SQLCipher build не включает
    /// `SQLITE_ENABLE_UPDATE_DELETE_LIMIT`, поэтому `LIMIT` допустим только
    /// во вложенном `SELECT`.
    public func deleteEventsOlderThan(tsMs: Int64, limit: Int) throws -> Int {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        guard limit > 0 else { return 0 }
        return try pool.write { db in
            try db.execute(
                sql: """
                DELETE FROM events WHERE id IN (
                    SELECT id FROM events WHERE ts < ? ORDER BY ts LIMIT ?
                )
                """,
                arguments: [tsMs, limit]
            )
            return db.changesCount
        }
    }

    /// Internal-intent bridge для LeafCorePrivate (moat-реализация
    /// Derived Insights), которой нужен raw GRDB handle для оконных функций
    /// и CTE. Не использовать из публичных callsites — публичные high-level
    /// accessors (`events(in:)`, `eventCount(in:)`) остаются primary API.
    /// Схема таблиц в whitepaper, конкретные query — в moat.
    public func readSQL<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try pool.read(block)
    }

    /// Internal-intent bridge на write transaction для unit-тестов
    /// (`PresenceStateWriterTests`). Production callsites используют
    /// высокоуровневые методы (`writeEventsOffsetAndPresence`,
    /// `writeEventsAndOffset`, `upsertIntegration` и т.д.) — этот handle
    /// не предназначен для них и поэтому `internal`, не `public`.
    internal func writeSQL<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        return try pool.write(block)
    }

    // MARK: - Collector offsets (Phase 2.3)

    /// Reads single offset by composite PK. Returns `nil` если записи нет —
    /// callsite (collector bootstrap branch) трактует как "ещё не видели этот файл".
    public func readOffset(collectorID: String, sourceID: String) throws -> CollectorOffset? {
        try pool.read { db in
            try Self.fetchOffset(db, collectorID: collectorID, sourceID: sourceID)
        }
    }

    /// Returns все offsets для данного `collectorID`. Order — по `sourceID` ASC
    /// для детерминизма (тесты ассертят последовательность).
    public func listOffsets(collectorID: String) throws -> [CollectorOffset] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Schema.CollectorOffsets.collectorID), \(Schema.CollectorOffsets.sourceID),
                       \(Schema.CollectorOffsets.byteOffset), \(Schema.CollectorOffsets.inode),
                       \(Schema.CollectorOffsets.size), \(Schema.CollectorOffsets.lastModifiedMs),
                       \(Schema.CollectorOffsets.updatedMs)
                FROM \(Schema.CollectorOffsets.tableName)
                WHERE \(Schema.CollectorOffsets.collectorID) = ?
                ORDER BY \(Schema.CollectorOffsets.sourceID) ASC
                """,
                arguments: [collectorID]
            ).map(Self.mapOffsetRow)
        }
    }

    /// UPSERT single offset — INSERT or UPDATE in-place. Writer-only.
    /// Для bootstrap rows и edge cases (skip-backward branch без events).
    /// Для совмещённого `events + offset` write используй `writeEventsAndOffset`.
    public func writeOffset(_ offset: CollectorOffset) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try Self.upsertOffset(offset, in: db)
        }
    }

    /// Atomic batch insert of `events` + offset UPSERT в одной транзакции.
    /// Phase 2.3 ClaudeCodeCollector — primary API: либо обе записи попадают
    /// в WAL, либо ни одной (Agent crash посреди flush → no duplicates +
    /// no lost-but-marked-as-read events). `offset == nil` допустим для
    /// чистых event-write'ов, но для regular collector flow всегда передаётся.
    public func writeEventsAndOffset(_ events: [RawEvent], offset: CollectorOffset?) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        guard !events.isEmpty || offset != nil else { return }

        let records = try events.map(EventRecord.make(from:))

        try pool.write { db in
            for var record in records {
                try record.insert(db)
            }
            if let offset {
                try Self.upsertOffset(offset, in: db)
            }
        }
    }

    /// Phase 4.7.B — atomic `events` + `offset` + `presence_state` UPSERT.
    /// All-or-nothing per tick: если presence write падает, cursor не двигается
    /// и ни одного event не вставляется → следующий tick пере-fetch'ит и
    /// перепишет presence на свежем snapshot'е. `presence == nil` допустим
    /// (тики, в которых нечего обновлять — например, polling response
    /// идентичен previous).
    public func writeEventsOffsetAndPresence(
        _ events: [RawEvent],
        offset: CollectorOffset,
        presence: (provider: PresenceStateWriter.Provider,
                   state: [String: Any],
                   derivedMode: String?)?,
        knownLinearPrefixes: Set<String> = [],
        derivers: LinkDerivers = .publicSubstrate,
        nowMs: Int64
    ) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }

        try pool.write { db in
            for event in events {
                _ = try Self.writeEventAndDerived(
                    event, knownLinearPrefixes: knownLinearPrefixes, derivers: derivers, in: db
                )
            }
            try Self.upsertOffset(offset, in: db)
            if let presence {
                try PresenceStateWriter.upsert(
                    provider: presence.provider,
                    state: presence.state,
                    derivedMode: presence.derivedMode,
                    nowMs: nowMs,
                    in: db
                )
            }
        }
    }

    /// Phase Track-3 D1 — atomic `events` + multi-offset + multi-snapshot UPSERT.
    /// Generalized form of `writeEventsAndOffset` for warm/cold collectors that
    /// (a) advance several offsets per tick (e.g. notifications + cycles cursors
    /// independently) and (b) update one or more provider_snapshots rows.
    ///
    /// All arrays may be empty (partial updates allowed). Single GRDB transaction:
    /// on any throw → full rollback (events not written, cursors not advanced,
    /// snapshots not upserted).
    public func writeEventsOffsetsAndSnapshots(
        events: [RawEvent],
        offsets: [CollectorOffset],
        snapshots: [ProviderSnapshot],
        knownLinearPrefixes: Set<String> = [],
        derivers: LinkDerivers = .publicSubstrate
    ) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        guard !events.isEmpty || !offsets.isEmpty || !snapshots.isEmpty else { return }

        try pool.write { db in
            for event in events {
                _ = try Self.writeEventAndDerived(
                    event, knownLinearPrefixes: knownLinearPrefixes, derivers: derivers, in: db
                )
            }
            for offset in offsets {
                try Self.upsertOffset(offset, in: db)
            }
            for snapshot in snapshots {
                try ProviderSnapshotsStore.upsert(snapshot, in: db)
            }
        }
    }

    // MARK: - Offset helpers (private)

    private static func fetchOffset(
        _ db: GRDB.Database,
        collectorID: String,
        sourceID: String
    ) throws -> CollectorOffset? {
        let row = try Row.fetchOne(db, sql: """
            SELECT \(Schema.CollectorOffsets.collectorID), \(Schema.CollectorOffsets.sourceID),
                   \(Schema.CollectorOffsets.byteOffset), \(Schema.CollectorOffsets.inode),
                   \(Schema.CollectorOffsets.size), \(Schema.CollectorOffsets.lastModifiedMs),
                   \(Schema.CollectorOffsets.updatedMs)
            FROM \(Schema.CollectorOffsets.tableName)
            WHERE \(Schema.CollectorOffsets.collectorID) = ?
              AND \(Schema.CollectorOffsets.sourceID) = ?
            """,
            arguments: [collectorID, sourceID]
        )
        return row.map(Self.mapOffsetRow)
    }

    private static func mapOffsetRow(_ row: Row) -> CollectorOffset {
        CollectorOffset(
            collectorID: row[Schema.CollectorOffsets.collectorID] as String,
            sourceID: row[Schema.CollectorOffsets.sourceID] as String,
            byteOffset: row[Schema.CollectorOffsets.byteOffset] as Int64,
            inode: row[Schema.CollectorOffsets.inode] as Int64?,
            size: row[Schema.CollectorOffsets.size] as Int64,
            lastModifiedMs: row[Schema.CollectorOffsets.lastModifiedMs] as Int64,
            updatedMs: row[Schema.CollectorOffsets.updatedMs] as Int64
        )
    }

    /// SQLite 3.24+ UPSERT (Zetetic SQLCipher 4.14 поверх 3.46+ — supported).
    /// Атомарно INSERT-or-UPDATE по composite PK (collector_id, source_id).
    private static func upsertOffset(_ offset: CollectorOffset, in db: GRDB.Database) throws {
        try db.execute(sql: """
            INSERT INTO \(Schema.CollectorOffsets.tableName) (
                \(Schema.CollectorOffsets.collectorID),
                \(Schema.CollectorOffsets.sourceID),
                \(Schema.CollectorOffsets.byteOffset),
                \(Schema.CollectorOffsets.inode),
                \(Schema.CollectorOffsets.size),
                \(Schema.CollectorOffsets.lastModifiedMs),
                \(Schema.CollectorOffsets.updatedMs)
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(\(Schema.CollectorOffsets.collectorID), \(Schema.CollectorOffsets.sourceID)) DO UPDATE SET
                \(Schema.CollectorOffsets.byteOffset)      = excluded.\(Schema.CollectorOffsets.byteOffset),
                \(Schema.CollectorOffsets.inode)           = excluded.\(Schema.CollectorOffsets.inode),
                \(Schema.CollectorOffsets.size)            = excluded.\(Schema.CollectorOffsets.size),
                \(Schema.CollectorOffsets.lastModifiedMs)  = excluded.\(Schema.CollectorOffsets.lastModifiedMs),
                \(Schema.CollectorOffsets.updatedMs)       = excluded.\(Schema.CollectorOffsets.updatedMs)
            """,
            arguments: [
                offset.collectorID,
                offset.sourceID,
                offset.byteOffset,
                offset.inode,
                offset.size,
                offset.lastModifiedMs,
                offset.updatedMs
            ]
        )
    }

    // MARK: - Watched folders (Phase 2.4)

    /// Returns watched folders ordered by `added_ts` ASC (детерминированный
    /// порядок для UI + tests). `includingDisabled=false` (default) — только
    /// `enabled=1`; UI Settings показывает все, FSEventsCollector — только enabled.
    public func listWatchedFolders(includingDisabled: Bool = false) throws -> [WatchedFolder] {
        try pool.read { db in
            let sql: String
            if includingDisabled {
                sql = """
                    SELECT \(Schema.WatchedFolders.id), \(Schema.WatchedFolders.path),
                           \(Schema.WatchedFolders.maxGranularity), \(Schema.WatchedFolders.enabled),
                           \(Schema.WatchedFolders.addedTs), \(Schema.WatchedFolders.updatedMs)
                    FROM \(Schema.WatchedFolders.tableName)
                    ORDER BY \(Schema.WatchedFolders.addedTs) ASC
                """
            } else {
                sql = """
                    SELECT \(Schema.WatchedFolders.id), \(Schema.WatchedFolders.path),
                           \(Schema.WatchedFolders.maxGranularity), \(Schema.WatchedFolders.enabled),
                           \(Schema.WatchedFolders.addedTs), \(Schema.WatchedFolders.updatedMs)
                    FROM \(Schema.WatchedFolders.tableName)
                    WHERE \(Schema.WatchedFolders.enabled) = 1
                    ORDER BY \(Schema.WatchedFolders.addedTs) ASC
                """
            }
            return try Row.fetchAll(db, sql: sql).compactMap(Self.mapWatchedFolderRow)
        }
    }

    /// INSERT — fails on UNIQUE(`path`) conflict (юзер пытается добавить
    /// already-watched folder). Caller обрабатывает GRDB DatabaseError SQLITE_CONSTRAINT.
    public func addWatchedFolder(_ folder: WatchedFolder) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO \(Schema.WatchedFolders.tableName) (
                    \(Schema.WatchedFolders.id),
                    \(Schema.WatchedFolders.path),
                    \(Schema.WatchedFolders.maxGranularity),
                    \(Schema.WatchedFolders.enabled),
                    \(Schema.WatchedFolders.addedTs),
                    \(Schema.WatchedFolders.updatedMs)
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    folder.id,
                    folder.path,
                    folder.maxGranularity.rawValue,
                    folder.enabled ? 1 : 0,
                    Int64(folder.addedAt.timeIntervalSince1970 * 1000),
                    Int64(folder.updatedAt.timeIntervalSince1970 * 1000)
                ]
            )
        }
    }

    /// DELETE by `id`. No-op если row не существует (idempotent — UI можно
    /// безопасно вызывать multiple раз).
    public func removeWatchedFolder(id: String) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try db.execute(sql: """
                DELETE FROM \(Schema.WatchedFolders.tableName) WHERE \(Schema.WatchedFolders.id) = ?
                """,
                arguments: [id]
            )
        }
    }

    /// Partial UPDATE. `nil` параметр — поле не меняется. `updated_ms` — bumped always
    /// при любом change (audit trail). No-op если оба `enabled` и `maxGranularity` nil.
    public func updateWatchedFolder(
        id: String,
        enabled: Bool? = nil,
        maxGranularity: WatchedFolderGranularity? = nil
    ) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        guard enabled != nil || maxGranularity != nil else { return }

        try pool.write { db in
            var sets: [String] = []
            var args: [DatabaseValueConvertible] = []
            if let enabled {
                sets.append("\(Schema.WatchedFolders.enabled) = ?")
                args.append(enabled ? 1 : 0)
            }
            if let maxGranularity {
                sets.append("\(Schema.WatchedFolders.maxGranularity) = ?")
                args.append(maxGranularity.rawValue)
            }
            sets.append("\(Schema.WatchedFolders.updatedMs) = ?")
            args.append(Int64(Date().timeIntervalSince1970 * 1000))
            args.append(id)

            try db.execute(
                sql: "UPDATE \(Schema.WatchedFolders.tableName) SET \(sets.joined(separator: ", ")) WHERE \(Schema.WatchedFolders.id) = ?",
                arguments: StatementArguments(args)
            )
        }
    }

    // MARK: - Integrations (Phase 4.1)

    /// UPSERT one integration row keyed by `provider`. Writer-only.
    /// Single-row-per-provider — переcoединение тех же workspace либо
    /// switch на другой workspace одного provider'а просто перезаписывает row.
    public func upsertIntegration(_ record: IntegrationRecord) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO \(Schema.Integrations.tableName) (
                    \(Schema.Integrations.provider),
                    \(Schema.Integrations.workspaceID),
                    \(Schema.Integrations.workspaceName),
                    \(Schema.Integrations.accessToken),
                    \(Schema.Integrations.refreshToken),
                    \(Schema.Integrations.expiresAtMs),
                    \(Schema.Integrations.scope),
                    \(Schema.Integrations.connectedAtMs),
                    \(Schema.Integrations.updatedMs)
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(\(Schema.Integrations.provider)) DO UPDATE SET
                    \(Schema.Integrations.workspaceID)   = excluded.\(Schema.Integrations.workspaceID),
                    \(Schema.Integrations.workspaceName) = excluded.\(Schema.Integrations.workspaceName),
                    \(Schema.Integrations.accessToken)   = excluded.\(Schema.Integrations.accessToken),
                    \(Schema.Integrations.refreshToken)  = excluded.\(Schema.Integrations.refreshToken),
                    \(Schema.Integrations.expiresAtMs)   = excluded.\(Schema.Integrations.expiresAtMs),
                    \(Schema.Integrations.scope)         = excluded.\(Schema.Integrations.scope),
                    \(Schema.Integrations.connectedAtMs) = excluded.\(Schema.Integrations.connectedAtMs),
                    \(Schema.Integrations.updatedMs)     = excluded.\(Schema.Integrations.updatedMs)
                """,
                arguments: [
                    record.provider.rawValue,
                    record.workspaceID,
                    record.workspaceName,
                    record.accessToken,
                    record.refreshToken,
                    record.expiresAt.map { Int64($0.timeIntervalSince1970 * 1000) },
                    record.scope,
                    Int64(record.connectedAt.timeIntervalSince1970 * 1000),
                    Int64(record.updatedAt.timeIntervalSince1970 * 1000)
                ]
            )
        }
    }

    /// Returns row keyed by `provider`, либо nil если ещё не подключено.
    /// Reader API — App потребляет в Settings UI rehydration, MCP/collector
    /// (Phase 4.2) — для polling auth.
    public func readIntegration(provider: IntegrationProvider) throws -> IntegrationRecord? {
        try pool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT \(Schema.Integrations.provider), \(Schema.Integrations.workspaceID),
                       \(Schema.Integrations.workspaceName), \(Schema.Integrations.accessToken),
                       \(Schema.Integrations.refreshToken), \(Schema.Integrations.expiresAtMs),
                       \(Schema.Integrations.scope), \(Schema.Integrations.connectedAtMs),
                       \(Schema.Integrations.updatedMs)
                FROM \(Schema.Integrations.tableName)
                WHERE \(Schema.Integrations.provider) = ?
                """,
                arguments: [provider.rawValue]
            )
            return row.flatMap(Self.mapIntegrationRow)
        }
    }

    /// DELETE by `provider`. Idempotent — no-op для отсутствующего row.
    /// "Disconnect" в UI; refresh-flow тоже вызывает при `invalid_grant`.
    public func deleteIntegration(provider: IntegrationProvider) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try db.execute(
                sql: "DELETE FROM \(Schema.Integrations.tableName) WHERE \(Schema.Integrations.provider) = ?",
                arguments: [provider.rawValue]
            )
        }
    }

    // MARK: - Team (Phase 5.1.B)

    /// UPSERT по `id`. Single-row-per-device convention (contract §4) — на DB
    /// уровне не enforced, идемпотентность создания + update'а `name` и
    /// `created_by_member_id` зашиты на UPSERT-семантику.
    public func upsertOrg(_ org: Org) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO \(Schema.Org.tableName) (
                    \(Schema.Org.id),
                    \(Schema.Org.name),
                    \(Schema.Org.createdAtMs),
                    \(Schema.Org.createdByMemberID)
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT(\(Schema.Org.id)) DO UPDATE SET
                    \(Schema.Org.name)              = excluded.\(Schema.Org.name),
                    \(Schema.Org.createdAtMs)       = excluded.\(Schema.Org.createdAtMs),
                    \(Schema.Org.createdByMemberID) = excluded.\(Schema.Org.createdByMemberID)
                """,
                arguments: [
                    org.id,
                    org.name,
                    Int64(org.createdAt.timeIntervalSince1970 * 1000),
                    org.createdByMemberID
                ]
            )
        }
    }

    /// Returns the single org row если present (contract §4). `LIMIT 1` —
    /// defensive под edge case "две rows" (схема не constrain'ит на 1 row).
    public func readOrg() throws -> Org? {
        try pool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT \(Schema.Org.id), \(Schema.Org.name),
                       \(Schema.Org.createdAtMs), \(Schema.Org.createdByMemberID)
                FROM \(Schema.Org.tableName)
                LIMIT 1
                """)
            return row.flatMap(Self.mapOrgRow)
        }
    }

    /// Strict INSERT — re-insert того же UUID — это bug (caller контролирует
    /// PK). Идемпотентность создания org+self-row на caller'е (5.1.D
    /// `OrgService.createPersonalOrg` проверяет `readOrg()` first).
    public func insertTeamMember(_ member: TeamMember) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO \(Schema.TeamMembers.tableName) (
                    \(Schema.TeamMembers.id),
                    \(Schema.TeamMembers.orgID),
                    \(Schema.TeamMembers.role),
                    \(Schema.TeamMembers.pubkeyHex),
                    \(Schema.TeamMembers.displayName),
                    \(Schema.TeamMembers.addedAtMs),
                    \(Schema.TeamMembers.removedAtMs)
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    member.id,
                    member.orgID,
                    member.role.rawValue,
                    member.pubkeyHex,
                    member.displayName,
                    Int64(member.addedAt.timeIntervalSince1970 * 1000),
                    member.removedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
                ]
            )
        }
    }

    /// Returns members одной org, ordered by `added_at_ms` ASC.
    /// `includeRemoved: false` (default) — active members only через partial
    /// index `team_members_org_active`. UI Team list — default-call.
    public func readTeamMembers(orgID: String, includeRemoved: Bool = false) throws -> [TeamMember] {
        try pool.read { db in
            let sql = """
                SELECT \(Schema.TeamMembers.id), \(Schema.TeamMembers.orgID),
                       \(Schema.TeamMembers.role), \(Schema.TeamMembers.pubkeyHex),
                       \(Schema.TeamMembers.displayName), \(Schema.TeamMembers.addedAtMs),
                       \(Schema.TeamMembers.removedAtMs)
                FROM \(Schema.TeamMembers.tableName)
                WHERE \(Schema.TeamMembers.orgID) = ?\
                \(includeRemoved ? "" : " AND \(Schema.TeamMembers.removedAtMs) IS NULL")
                ORDER BY \(Schema.TeamMembers.addedAtMs) ASC
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [orgID])
            return rows.compactMap(Self.mapTeamMemberRow)
        }
    }

    /// Strict INSERT — каждая rotation — уникальная запись (history forever-retained,
    /// contract §12). UUID PK collision = bug.
    public func insertTeamKey(_ key: TeamKey) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO \(Schema.TeamKeys.tableName) (
                    \(Schema.TeamKeys.id),
                    \(Schema.TeamKeys.generatedAtMs),
                    \(Schema.TeamKeys.deprecatedAtMs),
                    \(Schema.TeamKeys.generatedByMemberID)
                ) VALUES (?, ?, ?, ?)
                """,
                arguments: [
                    key.id,
                    Int64(key.generatedAt.timeIntervalSince1970 * 1000),
                    key.deprecatedAt.map { Int64($0.timeIntervalSince1970 * 1000) },
                    key.generatedByMemberID
                ]
            )
        }
    }

    /// Phase 5.3.E — idempotent variant of `insertTeamKey`. Used by `RotationFetchService`
    /// for crash-resilient peer install: peer fetches blob → unwraps → `insertTeamKeyIfAbsent`
    /// (succeeds on first install, no-op on retry after crash mid-`deprecateTeamKey`).
    /// Phase 5.3.C §10 invariant: composite-key dedup at relay means peer may receive
    /// same blob twice; second `insertTeamKey` would throw on PK collision; this helper
    /// swallows that path silently via `ON CONFLICT(id) DO NOTHING`.
    public func insertTeamKeyIfAbsent(_ key: TeamKey) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO \(Schema.TeamKeys.tableName) (
                    \(Schema.TeamKeys.id),
                    \(Schema.TeamKeys.generatedAtMs),
                    \(Schema.TeamKeys.deprecatedAtMs),
                    \(Schema.TeamKeys.generatedByMemberID)
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT(\(Schema.TeamKeys.id)) DO NOTHING
                """,
                arguments: [
                    key.id,
                    Int64(key.generatedAt.timeIntervalSince1970 * 1000),
                    key.deprecatedAt.map { Int64($0.timeIntervalSince1970 * 1000) },
                    key.generatedByMemberID
                ]
            )
        }
    }

    /// Returns latest active rotation (`deprecated_at_ms IS NULL` через partial
    /// index `team_keys_active`). ORDER+LIMIT — defensive под edge case "две
    /// active rows" (нормально 1 row, contract'ом на DB-уровне не constraint'ится).
    public func readActiveTeamKey() throws -> TeamKey? {
        try pool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT \(Schema.TeamKeys.id), \(Schema.TeamKeys.generatedAtMs),
                       \(Schema.TeamKeys.deprecatedAtMs), \(Schema.TeamKeys.generatedByMemberID)
                FROM \(Schema.TeamKeys.tableName)
                WHERE \(Schema.TeamKeys.deprecatedAtMs) IS NULL
                ORDER BY \(Schema.TeamKeys.generatedAtMs) DESC
                LIMIT 1
                """)
            return row.flatMap(Self.mapTeamKeyRow)
        }
    }

    // MARK: - Team lifecycle (Phase 5.3.A)

    /// Soft-delete на team_members row. Sets `removed_at_ms = at`. Idempotent
    /// re-call на already-removed row preserves original timestamp (silent no-op).
    /// Throws `LeafError.invalidPayload` если member не существует.
    public func markTeamMemberRemoved(memberID: String, at removedAt: Date) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try db.execute(sql: """
                UPDATE \(Schema.TeamMembers.tableName)
                SET \(Schema.TeamMembers.removedAtMs) = ?
                WHERE \(Schema.TeamMembers.id) = ?
                  AND \(Schema.TeamMembers.removedAtMs) IS NULL
                """,
                arguments: [
                    Int64(removedAt.timeIntervalSince1970 * 1000),
                    memberID
                ]
            )
            if db.changesCount == 1 { return }

            // changesCount == 0: либо already-removed (idempotent no-op), либо missing row.
            let row = try Row.fetchOne(db, sql: """
                SELECT \(Schema.TeamMembers.removedAtMs)
                FROM \(Schema.TeamMembers.tableName)
                WHERE \(Schema.TeamMembers.id) = ?
                LIMIT 1
                """,
                arguments: [memberID]
            )
            guard row != nil else { throw LeafError.invalidPayload }
            // row exists с не-NULL removed_at_ms → idempotent no-op, return.
        }
    }

    /// Marks team_keys row deprecated. Sets `deprecated_at_ms = at`.
    /// **Sole-active invariant:** throws `LeafError.invalidPayload` если
    /// deprecating этот key оставит 0 active rows. Caller (5.3.D KeyRotationService)
    /// должен `insertTeamKey(new)` first в той же tx.
    /// Idempotent re-call на already-deprecated row preserves original timestamp.
    /// Throws `LeafError.invalidPayload` если key не существует.
    public func deprecateTeamKey(keyID: String, at deprecatedAt: Date) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            // Step 1 — sole-active invariant guard.
            let activeCount = try Int.fetchOne(db, sql: """
                SELECT count(*)
                FROM \(Schema.TeamKeys.tableName)
                WHERE \(Schema.TeamKeys.deprecatedAtMs) IS NULL
                """) ?? 0
            if activeCount <= 1 {
                let targetActive = try Int.fetchOne(db, sql: """
                    SELECT count(*)
                    FROM \(Schema.TeamKeys.tableName)
                    WHERE \(Schema.TeamKeys.id) = ?
                      AND \(Schema.TeamKeys.deprecatedAtMs) IS NULL
                    """,
                    arguments: [keyID]
                ) ?? 0
                if targetActive == 1 {
                    // Target is the sole active row — deprecate would leave 0 active.
                    throw LeafError.invalidPayload
                }
                // Иначе — target либо already-deprecated (idempotent path),
                // либо missing (handled by zero-changesCount branch ниже).
                // Bypass guard, continue to step 2.
            }

            // Step 2 — conditional UPDATE.
            try db.execute(sql: """
                UPDATE \(Schema.TeamKeys.tableName)
                SET \(Schema.TeamKeys.deprecatedAtMs) = ?
                WHERE \(Schema.TeamKeys.id) = ?
                  AND \(Schema.TeamKeys.deprecatedAtMs) IS NULL
                """,
                arguments: [
                    Int64(deprecatedAt.timeIntervalSince1970 * 1000),
                    keyID
                ]
            )
            if db.changesCount == 1 { return }

            // changesCount == 0: либо already-deprecated (idempotent no-op),
            // либо missing row.
            let row = try Row.fetchOne(db, sql: """
                SELECT \(Schema.TeamKeys.deprecatedAtMs)
                FROM \(Schema.TeamKeys.tableName)
                WHERE \(Schema.TeamKeys.id) = ?
                LIMIT 1
                """,
                arguments: [keyID]
            )
            guard row != nil else { throw LeafError.invalidPayload }
            // row exists с не-NULL deprecated_at_ms → idempotent no-op.
        }
    }

    /// Returns team_keys row by id, regardless of deprecated status.
    /// Used by Phase 5.3.E peer-side flow для decrypt'а incoming snapshot
    /// под previously-rotated keyID (forever-retained per contract §12).
    /// Reader-mode safe — read-only API без mode guard.
    public func readTeamKey(byID id: String) throws -> TeamKey? {
        try pool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT \(Schema.TeamKeys.id), \(Schema.TeamKeys.generatedAtMs),
                       \(Schema.TeamKeys.deprecatedAtMs), \(Schema.TeamKeys.generatedByMemberID)
                FROM \(Schema.TeamKeys.tableName)
                WHERE \(Schema.TeamKeys.id) = ?
                LIMIT 1
                """,
                arguments: [id]
            )
            return row.flatMap(Self.mapTeamKeyRow)
        }
    }

    // MARK: - Rotation outbox (Phase 5.3.D)

    /// Atomic write of a key-rotation event: INSERT new `team_keys` row + UPDATE
    /// prior row's `deprecated_at_ms` + optional UPDATE `team_members.removed_at_ms`
    /// + INSERT N `rotation_outbox` rows. All within single `pool.write` block;
    /// rolls back on any failure.
    ///
    /// Sole-active guard relaxed (vs `deprecateTeamKey` 5.3.A) because new active
    /// row inserted in step 1 — at the time of step 2 deprecate, count >= 2.
    ///
    /// Throws `.databaseUnavailable` on reader-mode, `.invalidPayload` on:
    /// (removedMemberID, removedAt) nil-vs-non-nil mismatch; missing/already-deprecated
    /// prior key; missing/already-removed member; duplicate outbox composite key.
    public func commitRotation(
        newTeamKey: TeamKey,
        priorTeamKeyID: String,
        deprecatedAt: Date,
        removedMemberID: String?,
        removedAt: Date?,
        outboxRows: [RotationOutboxRow]
    ) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        // Pre-validation: removedMemberID and removedAt must be nil-together or non-nil-together.
        switch (removedMemberID, removedAt) {
        case (nil, nil), (.some, .some):
            break
        default:
            throw LeafError.invalidPayload
        }

        let priorDeprecatedAtMs = Int64(deprecatedAt.timeIntervalSince1970 * 1000)
        let newGeneratedAtMs = Int64(newTeamKey.generatedAt.timeIntervalSince1970 * 1000)
        let newDeprecatedAtMs: Int64? = newTeamKey.deprecatedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        let removedAtMs: Int64? = removedAt.map { Int64($0.timeIntervalSince1970 * 1000) }

        try pool.write { db in
            // Step 1: INSERT new team_keys row.
            try db.execute(sql: """
                INSERT INTO \(Schema.TeamKeys.tableName) (
                    \(Schema.TeamKeys.id),
                    \(Schema.TeamKeys.generatedAtMs),
                    \(Schema.TeamKeys.deprecatedAtMs),
                    \(Schema.TeamKeys.generatedByMemberID)
                ) VALUES (?, ?, ?, ?)
                """,
                arguments: [
                    newTeamKey.id,
                    newGeneratedAtMs,
                    newDeprecatedAtMs,
                    newTeamKey.generatedByMemberID
                ]
            )

            // Step 2: UPDATE prior team_keys deprecated_at_ms.
            try db.execute(sql: """
                UPDATE \(Schema.TeamKeys.tableName)
                SET \(Schema.TeamKeys.deprecatedAtMs) = ?
                WHERE \(Schema.TeamKeys.id) = ?
                  AND \(Schema.TeamKeys.deprecatedAtMs) IS NULL
                """,
                arguments: [priorDeprecatedAtMs, priorTeamKeyID]
            )
            if db.changesCount != 1 {
                // changesCount 0 → either missing row or already-deprecated. Both
                // surface as .invalidPayload per spec §9 (caller bug — admin shouldn't
                // initiate rotation от стейта где prior-key already deprecated/missing).
                throw LeafError.invalidPayload
            }

            // Step 3: optional UPDATE team_members removed_at_ms.
            if let memberID = removedMemberID, let memberRemovedMs = removedAtMs {
                try db.execute(sql: """
                    UPDATE \(Schema.TeamMembers.tableName)
                    SET \(Schema.TeamMembers.removedAtMs) = ?
                    WHERE \(Schema.TeamMembers.id) = ?
                      AND \(Schema.TeamMembers.removedAtMs) IS NULL
                    """,
                    arguments: [memberRemovedMs, memberID]
                )
                if db.changesCount != 1 {
                    // changesCount 0 → either missing row or already-removed; both → .invalidPayload.
                    throw LeafError.invalidPayload
                }
            }

            // Step 4: INSERT N rotation_outbox rows. Duplicate composite PK throws.
            for row in outboxRows {
                try db.execute(sql: """
                    INSERT INTO \(Schema.RotationOutbox.tableName) (
                        \(Schema.RotationOutbox.peerPubkeyHex),
                        \(Schema.RotationOutbox.newKeyID),
                        \(Schema.RotationOutbox.priorKeyID),
                        \(Schema.RotationOutbox.kind),
                        \(Schema.RotationOutbox.peerMemberID),
                        \(Schema.RotationOutbox.blob),
                        \(Schema.RotationOutbox.expiresAtMs),
                        \(Schema.RotationOutbox.createdAtMs),
                        \(Schema.RotationOutbox.postedAtMs)
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        row.peerPubkeyHex,
                        row.newKeyID,
                        row.priorKeyID,
                        row.kind.rawValue,
                        row.peerMemberID,
                        row.blob,
                        row.expiresAtMs,
                        row.createdAtMs,
                        row.postedAtMs as Int64?
                    ]
                )
            }
        }
    }

    /// Marks a rotation_outbox row posted. Composite key (peerPubkeyHex, newKeyID).
    /// Conditional UPDATE — silent no-op if already-posted (preserves first call's
    /// timestamp) or row missing (tolerant for crash-resume race where TTL purge or
    /// concurrent admin clears the row mid-iteration). Phase 5.3.D.
    public func markRotationOutboxPosted(
        peerPubkeyHex: String,
        newKeyID: String,
        at postedAt: Date
    ) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        let postedMs = Int64(postedAt.timeIntervalSince1970 * 1000)

        try pool.write { db in
            try db.execute(sql: """
                UPDATE \(Schema.RotationOutbox.tableName)
                SET \(Schema.RotationOutbox.postedAtMs) = ?
                WHERE \(Schema.RotationOutbox.peerPubkeyHex) = ?
                  AND \(Schema.RotationOutbox.newKeyID) = ?
                  AND \(Schema.RotationOutbox.postedAtMs) IS NULL
                """,
                arguments: [postedMs, peerPubkeyHex, newKeyID]
            )
            // changesCount 0 (already-posted or missing) tolerated silently.
            // changesCount 1 → success.
        }
    }

    /// Lists outbox rows where `posted_at_ms IS NULL`, ordered by `created_at_ms`
    /// ASC then `peer_pubkey_hex` ASC for determinism. Reader-mode safe.
    /// Phase 5.3.D — used by `KeyRotationService.resumePendingPosts()`.
    public func readUnpostedRotationOutboxRows() throws -> [RotationOutboxRow] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    \(Schema.RotationOutbox.peerPubkeyHex),
                    \(Schema.RotationOutbox.newKeyID),
                    \(Schema.RotationOutbox.priorKeyID),
                    \(Schema.RotationOutbox.kind),
                    \(Schema.RotationOutbox.peerMemberID),
                    \(Schema.RotationOutbox.blob),
                    \(Schema.RotationOutbox.expiresAtMs),
                    \(Schema.RotationOutbox.createdAtMs),
                    \(Schema.RotationOutbox.postedAtMs)
                FROM \(Schema.RotationOutbox.tableName)
                WHERE \(Schema.RotationOutbox.postedAtMs) IS NULL
                ORDER BY \(Schema.RotationOutbox.createdAtMs) ASC,
                         \(Schema.RotationOutbox.peerPubkeyHex) ASC
                """)
            return rows.compactMap(Self.mapRotationOutboxRow)
        }
    }

    private static func mapRotationOutboxRow(_ row: Row) -> RotationOutboxRow? {
        guard let peer: String = row[Schema.RotationOutbox.peerPubkeyHex],
              let newID: String = row[Schema.RotationOutbox.newKeyID],
              let priorID: String = row[Schema.RotationOutbox.priorKeyID],
              let kindRaw: String = row[Schema.RotationOutbox.kind],
              let kind = RotationKind(rawValue: kindRaw),
              let memberID: String = row[Schema.RotationOutbox.peerMemberID],
              let blob: Data = row[Schema.RotationOutbox.blob],
              let expiresMs: Int64 = row[Schema.RotationOutbox.expiresAtMs],
              let createdMs: Int64 = row[Schema.RotationOutbox.createdAtMs] else {
            return nil
        }
        let postedMs: Int64? = row[Schema.RotationOutbox.postedAtMs]
        return RotationOutboxRow(
            peerPubkeyHex: peer,
            newKeyID: newID,
            priorKeyID: priorID,
            kind: kind,
            peerMemberID: memberID,
            blob: blob,
            expiresAtMs: expiresMs,
            createdAtMs: createdMs,
            postedAtMs: postedMs
        )
    }

    // MARK: - Linear attribution v2 migration (Phase 4.5)

    /// Phase 4.5 — одноразовая wipe Linear events + cursor для миграции на
    /// per-action attribution. Старая query `{updatedAt:{gt:$since}}` была
    /// workspace-wide и засчитывала teammate updates как user actions; existing
    /// rows контаминированы. Caller (`LinearCollector.runOneTimeMigration`)
    /// гарантирует idempotency через UserDefaults flag.
    /// Возвращает `(eventsDeleted, offsetsDeleted)` для diagnostic logging.
    public func purgeLinearAttributionV2() throws -> (eventsDeleted: Int, offsetsDeleted: Int) {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        return try pool.write { db in
            try db.execute(
                sql: """
                DELETE FROM \(Schema.Events.tableName)
                WHERE \(Schema.Events.signalType) = ?
                  AND json_extract(\(Schema.Events.payloadJSON), '$.source') = 'linear'
                """,
                arguments: [SignalType.action.rawValue]
            )
            let eventsDeleted = db.changesCount
            try db.execute(
                sql: """
                DELETE FROM \(Schema.CollectorOffsets.tableName)
                WHERE \(Schema.CollectorOffsets.collectorID) = ?
                """,
                arguments: [CollectorID.linearPolling]
            )
            let offsetsDeleted = db.changesCount
            return (eventsDeleted, offsetsDeleted)
        }
    }

    // MARK: - GitHub collector helpers (Phase 4.7.B-3)

    /// Phase 4.7.B-3 — derive top-N repos для bounded fan-out actions/runs polling.
    /// Возвращает "owner/repo" identifier'ы упорядоченные по count `commit_pushed`
    /// events DESC начиная с `sinceMs` (typically `now - 7 days`).
    /// Используется `GitHubCollector.performTick()` перед `fetchActionsRunsForActor` —
    /// ограничивает per-tick HTTP cost N calls (one per repo) и фокусирует на
    /// реально активных репо. Empty result → no actions/runs HTTP call вообще.
    /// Reader-mode safe (read-only). Returns repos in DESC order by push count.
    public func queryActiveGitHubRepos(sinceMs: Int64, limit: Int) throws -> [String] {
        guard limit > 0 else { return [] }
        return try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT json_extract(\(Schema.Events.payloadJSON), '$.repo') AS repo,
                       COUNT(*) AS c
                FROM \(Schema.Events.tableName)
                WHERE json_extract(\(Schema.Events.payloadJSON), '$.source') = 'github'
                  AND json_extract(\(Schema.Events.payloadJSON), '$.event_kind') = 'commit_pushed'
                  AND \(Schema.Events.ts) >= ?
                  AND json_extract(\(Schema.Events.payloadJSON), '$.repo') IS NOT NULL
                GROUP BY repo
                ORDER BY c DESC
                LIMIT ?
                """,
                arguments: [sinceMs, limit]
            ).compactMap { $0["repo"] as String? }
        }
    }

    // MARK: - Slack collector helpers (Phase 4.4)

    /// Phase 4.4 B6 — узкий summary для последнего Slack `huddle_state_change`
    /// context-event. Полная `RawEvent` reconstruction collector'у не нужна —
    /// он сравнивает только `state` для transition detection.
    public struct SlackHuddleEventSummary: Sendable, Equatable {
        /// Raw API string ("in_a_huddle" / "default_unset" / etc) — collector
        /// сам конвертит в `SlackHuddleState` через `init(slackAPIString:)`,
        /// чтобы forward-compat с unknown values остался у одного callsite.
        public let state: String
        public let tsMs: Int64

        public init(state: String, tsMs: Int64) {
            self.state = state
            self.tsMs = tsMs
        }
    }

    /// Возвращает (state, ts_ms) последнего slack huddle_state_change context-event,
    /// или nil если ни одного нет в DB. Используется SlackCollector для transition
    /// detection. Фильтр по `signal_type='context'` + JSON1 `payload.source='slack'`
    /// + `payload.event_kind='huddle_state_change'` исключает action events
    /// (message aggregates) и события других providers.
    public func readLatestSlackHuddleEvent() throws -> SlackHuddleEventSummary? {
        try pool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT json_extract(\(Schema.Events.payloadJSON), '$.state') AS state,
                       \(Schema.Events.ts) AS ts_ms
                FROM \(Schema.Events.tableName)
                WHERE \(Schema.Events.signalType) = ?
                  AND json_extract(\(Schema.Events.payloadJSON), '$.source') = 'slack'
                  AND json_extract(\(Schema.Events.payloadJSON), '$.event_kind') = 'huddle_state_change'
                  AND json_extract(\(Schema.Events.payloadJSON), '$.state') IS NOT NULL
                ORDER BY \(Schema.Events.ts) DESC
                LIMIT 1
                """,
                arguments: [SignalType.context.rawValue]
            )
            guard
                let row,
                let state = row["state"] as String?,
                let tsMs = row["ts_ms"] as Int64?
            else { return nil }
            return SlackHuddleEventSummary(state: state, tsMs: tsMs)
        }
    }

    private static func mapIntegrationRow(_ row: Row) -> IntegrationRecord? {
        guard
            let providerRaw = row[Schema.Integrations.provider] as String?,
            let provider = IntegrationProvider(rawValue: providerRaw),
            let workspaceID = row[Schema.Integrations.workspaceID] as String?,
            let workspaceName = row[Schema.Integrations.workspaceName] as String?,
            let accessToken = row[Schema.Integrations.accessToken] as String?,
            let scope = row[Schema.Integrations.scope] as String?,
            let connectedAtMs = row[Schema.Integrations.connectedAtMs] as Int64?,
            let updatedMs = row[Schema.Integrations.updatedMs] as Int64?
        else { return nil }
        let refreshToken = row[Schema.Integrations.refreshToken] as String?
        let expiresAtMs = row[Schema.Integrations.expiresAtMs] as Int64?
        return IntegrationRecord(
            provider: provider,
            workspaceID: workspaceID,
            workspaceName: workspaceName,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAtMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) },
            scope: scope,
            connectedAt: Date(timeIntervalSince1970: TimeInterval(connectedAtMs) / 1000.0),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedMs) / 1000.0)
        )
    }

    private static func mapOrgRow(_ row: Row) -> Org? {
        guard
            let id = row[Schema.Org.id] as String?,
            let name = row[Schema.Org.name] as String?,
            let createdAtMs = row[Schema.Org.createdAtMs] as Int64?,
            let createdByMemberID = row[Schema.Org.createdByMemberID] as String?
        else { return nil }
        return Org(
            id: id,
            name: name,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAtMs) / 1000.0),
            createdByMemberID: createdByMemberID
        )
    }

    private static func mapTeamMemberRow(_ row: Row) -> TeamMember? {
        guard
            let id = row[Schema.TeamMembers.id] as String?,
            let orgID = row[Schema.TeamMembers.orgID] as String?,
            let roleRaw = row[Schema.TeamMembers.role] as String?,
            let role = TeamMemberRole(rawValue: roleRaw),
            let pubkeyHex = row[Schema.TeamMembers.pubkeyHex] as String?,
            let displayName = row[Schema.TeamMembers.displayName] as String?,
            let addedAtMs = row[Schema.TeamMembers.addedAtMs] as Int64?
        else { return nil }
        let removedAtMs = row[Schema.TeamMembers.removedAtMs] as Int64?
        return TeamMember(
            id: id,
            orgID: orgID,
            role: role,
            pubkeyHex: pubkeyHex,
            displayName: displayName,
            addedAt: Date(timeIntervalSince1970: TimeInterval(addedAtMs) / 1000.0),
            removedAt: removedAtMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
        )
    }

    private static func mapTeamKeyRow(_ row: Row) -> TeamKey? {
        guard
            let id = row[Schema.TeamKeys.id] as String?,
            let generatedAtMs = row[Schema.TeamKeys.generatedAtMs] as Int64?,
            let generatedByMemberID = row[Schema.TeamKeys.generatedByMemberID] as String?
        else { return nil }
        let deprecatedAtMs = row[Schema.TeamKeys.deprecatedAtMs] as Int64?
        return TeamKey(
            id: id,
            generatedAt: Date(timeIntervalSince1970: TimeInterval(generatedAtMs) / 1000.0),
            deprecatedAt: deprecatedAtMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) },
            generatedByMemberID: generatedByMemberID
        )
    }

    private static func mapWatchedFolderRow(_ row: Row) -> WatchedFolder? {
        guard
            let id = row[Schema.WatchedFolders.id] as String?,
            let path = row[Schema.WatchedFolders.path] as String?,
            let granularityRaw = row[Schema.WatchedFolders.maxGranularity] as String?,
            let granularity = WatchedFolderGranularity(rawValue: granularityRaw),
            let enabledInt = row[Schema.WatchedFolders.enabled] as Int?,
            let addedTsMs = row[Schema.WatchedFolders.addedTs] as Int64?,
            let updatedMs = row[Schema.WatchedFolders.updatedMs] as Int64?
        else { return nil }
        return WatchedFolder(
            id: id,
            path: path,
            maxGranularity: granularity,
            enabled: enabledInt == 1,
            addedAt: Date(timeIntervalSince1970: TimeInterval(addedTsMs) / 1000.0),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedMs) / 1000.0)
        )
    }

    // MARK: - Helpers

    private static func ensureDirectory(for url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Устанавливает `prepareDatabase` hook на GRDB Configuration, применяющий
    /// SQLCipher pragmas per-connection. Ordering: pre-key → `PRAGMA key = x'HEX'` → post-key.
    /// Если `opts == nil` — ничего не делаем, DB открывается как plaintext SQLite.
    private static func applyEncryption(_ opts: EncryptionOptions?, to config: inout Configuration) {
        guard let opts else { return }
        config.prepareDatabase { db in
            for pragma in opts.preKeyPragmas {
                try db.execute(sql: "PRAGMA \(pragma.name) = \(pragma.value)")
            }
            let key = try opts.keyProvider.resolve()
            let hex = key.map { String(format: "%02x", $0) }.joined()
            try db.execute(sql: "PRAGMA key = \"x'\(hex)'\"")
            for pragma in opts.postKeyPragmas {
                try db.execute(sql: "PRAGMA \(pragma.name) = \(pragma.value)")
            }
        }
    }

    /// Detection + rename plaintext SQLite при первом encrypted-boot.
    /// Запускается только в writer mode (юзер уже писал → что-то есть для миграции),
    /// и только если передан encryption (nil = остаёмся на plaintext).
    /// Strategy (D-1.5-2): если первые 16 байт == "SQLite format 3\0" → переименовать
    /// в `events.sqlite.pre-sqlcipher.bak`, удалить WAL/SHM sidecar'ы, запустить
    /// нормальный open-flow (создаст свежую encrypted).
    private static func migrateFromPlaintextIfNeeded(at url: URL, encryption: EncryptionOptions?) throws {
        guard encryption != nil else { return }
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { return }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 16) ?? Data()
        guard header == Data("SQLite format 3\0".utf8) else { return }

        let backup = url.appendingPathExtension("pre-sqlcipher.bak")
        try FileManager.default.moveItem(at: url, to: backup)
        for ext in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: path + ext)
            if FileManager.default.fileExists(atPath: side.path) {
                try? FileManager.default.removeItem(at: side)
            }
        }
        Logger(subsystem: "tech.gundem.leaf.core", category: "db")
            .warning("Plaintext SQLite detected at \(path, privacy: .public), renamed to \(backup.path, privacy: .public). Starting fresh encrypted DB.")
    }

    // MARK: - Pending invites (Phase 5.5.B)

    /// Append a `pending_invites` row. Mirror `upsertOrg` / `insertTeamMember` ordering —
    /// caller (InviteOutboxReader) controls PK uniqueness via relay-issued token.
    public func insertPendingInvite(_ row: PendingInvite) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try PendingInvitesStore.insert(row, in: db)
        }
    }

    /// UPDATE pending_invites.status. Idempotent silent no-op if token missing.
    public func updatePendingInviteStatus(token: String, status: PendingInviteStatus) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try PendingInvitesStore.updateStatus(token: token, status: status, in: db)
        }
    }

    // MARK: - Pending invites (Phase 5.5.C — read / sweep / delete / poll-stamp)

    /// Read all `pending_invites` rows visible to UI list (excludes `.consumed`),
    /// ordered by `created_at_ms` DESC. Reader pool — mode-agnostic.
    public func readAllPendingInvites() throws -> [PendingInvite] {
        try pool.read { db in
            try PendingInvitesStore.readAllExcludingConsumed(in: db)
        }
    }

    /// Read all `pending_invites` rows filtered by exact status (used by poll loop).
    public func readAllPendingInvitesByStatus(_ status: PendingInviteStatus) throws -> [PendingInvite] {
        try pool.read { db in
            try PendingInvitesStore.readAll(status: status, in: db)
        }
    }

    /// DELETE `pending_invites` row by PK. Idempotent — silent no-op on missing row.
    public func deletePendingInvite(token: String) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try PendingInvitesStore.delete(token: token, in: db)
        }
    }

    /// UPDATE `pending_invites.last_polled_at_ms`. Idempotent — silent no-op on missing token.
    public func updatePendingInviteLastPolledAt(token: String, atMs: Int64) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try PendingInvitesStore.updateLastPolledAt(token: token, atMs: atMs, in: db)
        }
    }

    /// Sweep `.pending` rows past `expires_at_ms` deadline → `.expired`. Returns affected count.
    /// Used by `PendingInvitesService.{loadVisible,pollPending}` (D8 — sweep at TeamView .onAppear
    /// + post-Refresh).
    public func sweepExpiredPendingInvites(nowMs: Int64) throws -> Int {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        return try pool.write { db in
            try PendingInvitesStore.sweepExpired(nowMs: nowMs, in: db)
        }
    }
}

// MARK: - EventRecord conversion

private extension EventRecord {
    static func make(from event: RawEvent) throws -> EventRecord {
        let payloadData = try JSONEncoder().encode(event.payload)
        let payloadJSON = String(decoding: payloadData, as: UTF8.self)
        let tsMs = Int64(event.timestamp.timeIntervalSince1970 * 1000)

        return EventRecord(
            id: nil,
            ts: tsMs,
            signalType: event.signalType.rawValue,
            bundleID: event.bundleID,
            payloadJSON: payloadJSON
        )
    }

    func toRawEvent() throws -> RawEvent {
        let payload: [String: String]
        if let data = payloadJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            payload = decoded
        } else {
            payload = [:]
        }

        guard let signal = SignalType(rawValue: signalType) else {
            throw LeafError.invalidPayload
        }

        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(ts) / 1000.0),
            signalType: signal,
            bundleID: bundleID,
            payload: payload
        )
    }
}
