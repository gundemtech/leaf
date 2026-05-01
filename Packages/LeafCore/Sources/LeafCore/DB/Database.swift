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

    public func write(_ event: RawEvent) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }

        let record = try EventRecord.make(from: event)

        try pool.write { db in
            var mutableRecord = record
            try mutableRecord.insert(db)
        }
    }

    public func write(_ events: [RawEvent]) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        guard !events.isEmpty else { return }

        let records = try events.map(EventRecord.make(from:))

        try pool.write { db in
            for var record in records {
                try record.insert(db)
            }
        }
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
        nowMs: Int64
    ) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }

        let records = try events.map(EventRecord.make(from:))

        try pool.write { db in
            for var record in records {
                try record.insert(db)
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
