import Foundation
import GRDB
import os

/// GRDB 7.x wrapper with optional SQLCipher encryption.
/// Writer (Agent) and Reader (App / MCP) are separate `Database` instances over the same file via WAL.
/// `encryption: nil` on open* → plaintext (CI / unit tests). `.some(...)` → SQLCipher-encrypted.
public final class Database: @unchecked Sendable {
    public enum Mode: Sendable { case writer, reader }

    /// Exposed for LeafCorePrivate (moat): `DBDomainAllowListReader` needs the
    /// underlying `DatabasePool` to issue read-only queries. Must not be used
    /// for writes outside of `Database` itself.
    public let pool: DatabasePool
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
        purgeStalePlaintextBackupIfNeeded(at: url)

        var grdbConfig = Configuration()
        grdbConfig.readonly = false
        grdbConfig.busyMode = .timeout(TimeInterval(config.busyTimeoutMs) / 1000.0)
        applyEncryption(encryption, to: &grdbConfig)

        let pool = try DatabasePool(path: url.path, configuration: grdbConfig)

        let migrator = makeAppMigrator()
        // Ph C migration-guard (R7): if the DB carries migrations this binary does
        // not know (written by a newer Leaf build), refuse to migrate — surface a
        // recovery path instead of mangling/“Couldn't load Home”.
        try assertSchemaNotFromFuture(pool, migrator: migrator)
        try migrator.migrate(pool)

        return Database(pool: pool, config: config, mode: .writer)
    }

    /// All registered schema migrations, in order. Single source of truth shared
    /// by `openForWrite` (which migrates) and the read/write schema guard (which
    /// only needs the registered identifier set). Adding a migration = append one
    /// `registerMigrationNNN…()` line here (next number, never reuse — see
    /// scripts/check-migrations.sh).
    static func makeAppMigrator() -> DatabaseMigrator {
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
        migrator.registerMigration016NormalizeGitHubEventKinds()
        migrator.registerMigration017NormalizeSlackEventKinds()
        migrator.registerMigration018IntensityAggregates()
        migrator.registerMigration019Workspaces()
        migrator.registerMigration020MessagesMirror()
        migrator.registerMigration021APNsTokenLocal()
        migrator.registerMigration022ShareRules()
        migrator.registerMigration023TeamEventsMirror()
        migrator.registerMigration024TeamEventBroadcastOffsets()
        migrator.registerMigration025WorkspaceSoftDelete()
        migrator.registerMigration026S8Substrate()
        migrator.registerMigration027InviteSystemRedesign()
        // M028 — Track-6 P1 (renamed from M024; slot M024 occupied by Track-5/S5/S7
        // broadcast offsets on integration-T10 branch).
        migrator.registerMigration028ClaudeCodeAISubagentIndex()
        // M029 — Track-6 P3 (renamed from M026; slot M026 occupied by Track-5/S8
        // substrate on integration-T10 branch).
        migrator.registerMigration029BrowserDomainAllow()
        // M030 — Track-6 P4 GoogleCalendar (renamed from dev M027; slot M027
        // occupied by InviteSystemRedesign on the integration trunk). Clean
        // append after M029 — Ph B trunk unification.
        migrator.registerMigration030GoogleCalendarTracker()
        return migrator
    }

    /// Throws `LeafError.databaseSchemaFromFuture` if the database has applied
    /// migration identifiers the supplied migrator does not register — i.e. the
    /// file was written by a newer Leaf build. GRDB's `migrate()` would silently
    /// ignore unknown applied migrations, so this explicit check is required on
    /// BOTH the writer and reader paths (MCP read tools use `openForRead`).
    static func assertSchemaNotFromFuture(_ pool: DatabasePool, migrator: DatabaseMigrator) throws {
        guard try pool.read(migrator.hasBeenSuperseded) else { return }
        let unknown = try pool.read(migrator.appliedIdentifiers)
            .subtracting(migrator.migrations)
            .sorted()
        throw LeafError.databaseSchemaFromFuture(unknown: unknown)
    }

    /// Move the database file and its `-wal`/`-shm` sidecars aside to timestamped
    /// backups, freeing the path so the next `openForWrite` creates a fresh DB.
    /// Backs the "Backup & Reset" action of the migration-guard recovery alert
    /// (Ph C / D-C4). The plaintext-migration backup (`events.sqlite.pre-sqlcipher.bak`)
    /// is intentionally NOT part of the moved set. Returns the main backup URL.
    ///
    /// The caller MUST ensure no process still holds the DB open (stop the Agent
    /// first) — this only moves files, it does not coordinate cross-process locks.
    /// `now` is injectable for deterministic tests.
    @discardableResult
    public static func backupAndReset(at url: URL, now: Date = Date()) throws -> URL {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = "backup-\(fmt.string(from: now))"

        let fm = FileManager.default
        let candidates = [
            url,
            URL(fileURLWithPath: url.path + "-wal"),
            URL(fileURLWithPath: url.path + "-shm"),
        ]
        for src in candidates {
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = src.appendingPathExtension(suffix)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.moveItem(at: src, to: dst)
        }
        Logger(subsystem: "tech.gundem.leaf.core", category: "db")
            .warning(
                "backupAndReset: moved DB + sidecars aside as .\(suffix, privacy: .public); a fresh DB will be created on next open."
            )
        return url.appendingPathExtension(suffix)
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
        // Ph C migration-guard (R7): readers (MCP tools) never run the migrator,
        // so a future-schema DB would otherwise serve partial/garbled data. Refuse.
        try assertSchemaNotFromFuture(pool, migrator: makeAppMigrator())
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

    /// Forced `PRAGMA wal_checkpoint(TRUNCATE)`.
    /// With active readers SQLite may perform a partial checkpoint (advancing only
    /// to the hwm of the most-lagging reader) — this is expected graceful degradation, not an error.
    /// In that case the WAL file won't shrink to 0, but will keep being kept in check by the next
    /// successful checkpoint. No retry / force needed.
    public func checkpointWAL() throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.writeWithoutTransaction { db in
            _ = try db.checkpoint(.truncate)
        }
    }

    /// Deletes up to `limit` oldest rows from `events` with `ts < tsMs`.
    /// Returns the actual number of deleted rows (`db.changesCount`).
    /// Used by the retention sweep in `MaintenanceScheduler`; called in a loop,
    /// while `return < limit` — chunk by chunk, so as not to hold the writer transaction
    /// longer than `busyTimeoutMs` on million-row tables.
    ///
    /// Subquery pattern (not `DELETE ... LIMIT ?`): the SQLCipher build does not include
    /// `SQLITE_ENABLE_UPDATE_DELETE_LIMIT`, so `LIMIT` is only allowed
    /// inside the nested `SELECT`.
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

    /// Internal-intent bridge for LeafCorePrivate (the moat implementation
    /// of Derived Insights), which needs a raw GRDB handle for window functions
    /// and CTEs. Do not use from public callsites — the public high-level
    /// accessors (`events(in:)`, `eventCount(in:)`) remain the primary API.
    /// Table schema is in the whitepaper, the concrete queries are in the moat.
    public func readSQL<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try pool.read(block)
    }

    // MARK: - Phase Track-4 S3 — intensity_aggregates

    /// UPSERT of a per-minute bucket of counter-only intensity. Idempotent by PK
    /// `minute_bucket_ms` — a re-flush on agent restart overwrites the row.
    public func upsertIntensityAggregate(
        minuteBucketMs: Int64,
        keystrokes: Int,
        mouseMoves: Int,
        appSwitches: Int,
        foregroundApp: String?
    ) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try IntensityAggregatesStore.upsert(
                minuteBucketMs: minuteBucketMs,
                keystrokes: keystrokes,
                mouseMoves: mouseMoves,
                appSwitches: appSwitches,
                foregroundApp: foregroundApp,
                in: db
            )
        }
    }

    public func readIntensityAggregates(range: Range<Int64>) throws -> [IntensityAggregateRecord] {
        try pool.read { db in
            try IntensityAggregatesStore.read(range: range, in: db)
        }
    }

    /// Retention sweep — called by `MaintenanceScheduler` with the same cutoff
    /// as `deleteEventsOlderThan`.
    public func purgeIntensityAggregates(before cutoffMs: Int64) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try IntensityAggregatesStore.purge(before: cutoffMs, in: db)
        }
    }

    /// Internal-intent bridge to a write transaction for unit tests
    /// (`PresenceStateWriterTests`). Production callsites use the
    /// high-level methods (`writeEventsOffsetAndPresence`,
    /// `writeEventsAndOffset`, `upsertIntegration`, etc.) — this handle
    /// is not meant for them, which is why it is `internal`, not `public`.
    internal func writeSQL<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        return try pool.write(block)
    }

    // MARK: - Share rules (Track 5 / S5)

    public func readShareRules(workspaceID: String) throws -> [ShareSource: Bool] {
        try pool.read { rawDB in
            try ShareRulesStore.readEffective(workspaceID: workspaceID, in: rawDB)
        }
    }

    public func isShareRuleEnabled(workspaceID: String, source: ShareSource) throws -> Bool {
        try pool.read { rawDB in
            try ShareRulesStore.isEnabled(workspaceID: workspaceID, source: source, in: rawDB)
        }
    }

    public func upsertShareRule(
        workspaceID: String,
        source: ShareSource,
        enabled: Bool,
        updatedAtMs: Int64
    ) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { rawDB in
            try ShareRulesStore.upsert(
                workspaceID: workspaceID,
                source: source,
                enabled: enabled,
                updatedAtMs: updatedAtMs,
                in: rawDB
            )
        }
    }

    // MARK: - Notification prefs (Track 5 / S8 / T1 + T9)

    /// SELECT all rows + seed defaults from `NotificationKind.defaultEnabled`.
    /// Used by `NotificationPrefsReader` (T9) to bind toggles in the
    /// Notifications Settings section. Cheap — 11-row scan max.
    public func readNotificationPrefs() throws -> [NotificationKind: Bool] {
        try pool.read { rawDB in
            try NotificationPrefsStore.readEffective(in: rawDB)
        }
    }

    /// Convenience single-kind resolution incorporating defaults. Used by
    /// callers (e.g., `apns_push` Edge Function mirror lookup) that only
    /// want one kind's effective state.
    public func isNotificationPrefEnabled(_ kind: NotificationKind) throws -> Bool {
        try pool.read { rawDB in
            try NotificationPrefsStore.isEnabled(kind, in: rawDB)
        }
    }

    /// UPSERT toggle per `NotificationKind`. Rejects disabling a locked kind
    /// (currently `.handoff`) via `NotificationPrefsStore.Error.cannotDisableLockedKind`.
    /// Caller (`NotificationPrefsReader.setEnabled`) refreshes the in-memory map
    /// after the write and surfaces the locked-kind error silently (UI shows
    /// the lock icon + disabled toggle so the call shouldn't fire in normal flow).
    public func setNotificationPref(
        _ kind: NotificationKind,
        enabled: Bool,
        updatedAtMs: Int64
    ) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { rawDB in
            try NotificationPrefsStore.setEnabled(
                kind,
                enabled: enabled,
                updatedAtMs: updatedAtMs,
                in: rawDB
            )
        }
    }

    // MARK: - Direct message mirror (Track 5 / S4 + S7)

    /// Single-pass aggregate: number of unread inbound DMs per workspace.
    /// Uses the `idx_messages_mirror_unread` partial index — cheap at any DB size.
    /// Called by `DirectMessageInboxReader.refreshUnreadCounts()` after every tick
    /// + every Realtime push absorption.
    public func readUnreadDMCountByWorkspace() throws -> [String: Int] {
        try pool.read { rawDB in
            try MessagesMirrorStore.unreadInboundCountByWorkspace(in: rawDB)
        }
    }

    // MARK: - Team event mirror retention (Track 5 / S5)

    public func deleteTeamEventMirrorOlderThan(cutoffMs: Int64) throws -> Int {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        return try pool.write { rawDB in
            try TeamEventMirrorStore.deleteOlderThan(cutoffMs: cutoffMs, in: rawDB)
        }
    }

    // MARK: - Direct message pending_mark_done retry queue (Track 5 / S8 T6)

    /// SELECT `message_id` rows where `pending_mark_done = 1`. Drives
    /// `PendingMarkDoneRetryService.tick()`. Uses the M026 partial index for
    /// O(pending) seek.
    public func readPendingMarkDoneMessageIDs() throws -> [String] {
        try pool.read { rawDB in
            try MessagesMirrorStore.fetchPendingMarkDoneIDs(in: rawDB)
        }
    }

    /// UPDATE `pending_mark_done` flag — set to 1 after the optimistic local
    /// UPDATE landed but the server PATCH failed; cleared back to 0 by the
    /// retry queue on a subsequent successful PATCH.
    public func writePendingMarkDoneFlag(messageID: String, pending: Bool) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { rawDB in
            try MessagesMirrorStore.setPendingMarkDone(
                messageID: messageID, pending: pending, in: rawDB
            )
        }
    }

    /// Optimistic-local `markDone` — UPDATE done_at + done_by_pubkey + clear
    /// pending_mark_done in one statement. Distinct from
    /// `MessagesMirrorStore.markDone` (post-server-confirmed path) since this
    /// variant runs FIRST in the APNs dm.markDone flow (server PATCH may fail
    /// and a separate `writePendingMarkDoneFlag(pending: true)` writes the
    /// retry-queue flag).
    public func writeOptimisticMarkDone(
        messageID: String,
        atMs: Int64,
        doneByPubkeyHex: String
    ) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { rawDB in
            try MessagesMirrorStore.markDoneLocalOptimistic(
                messageID: messageID,
                atMs: atMs,
                doneByPubkeyHex: doneByPubkeyHex,
                in: rawDB
            )
        }
    }

    // MARK: - Collector offsets (Phase 2.3)

    /// Reads single offset by composite PK. Returns `nil` if there is no row —
    /// the callsite (collector bootstrap branch) treats it as "haven't seen this file yet".
    public func readOffset(collectorID: String, sourceID: String) throws -> CollectorOffset? {
        try pool.read { db in
            try Self.fetchOffset(db, collectorID: collectorID, sourceID: sourceID)
        }
    }

    /// Returns all offsets for the given `collectorID`. Order is by `sourceID` ASC
    /// for determinism (tests assert the sequence).
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
    /// For bootstrap rows and edge cases (skip-backward branch without events).
    /// For a combined `events + offset` write use `writeEventsAndOffset`.
    public func writeOffset(_ offset: CollectorOffset) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try Self.upsertOffset(offset, in: db)
        }
    }

    /// Atomic batch insert of `events` + offset UPSERT in a single transaction.
    /// Phase 2.3 ClaudeCodeCollector — primary API: either both writes land
    /// in the WAL, or neither (Agent crash mid-flush → no duplicates +
    /// no lost-but-marked-as-read events). `offset == nil` is allowed for
    /// pure event-writes, but for the regular collector flow it is always passed.
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
    /// All-or-nothing per tick: if the presence write fails, the cursor does not move
    /// and not a single event is inserted → the next tick re-fetches and
    /// rewrites presence on a fresh snapshot. `presence == nil` is allowed
    /// (ticks with nothing to update — for example, a polling response
    /// identical to the previous one).
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

    /// SQLite 3.24+ UPSERT (Zetetic SQLCipher 4.14 on top of 3.46+ — supported).
    /// Atomically INSERT-or-UPDATE by the composite PK (collector_id, source_id).
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

    /// Returns watched folders ordered by `added_ts` ASC (deterministic
    /// order for UI + tests). `includingDisabled=false` (default) — only
    /// `enabled=1`; UI Settings shows all, FSEventsCollector — only enabled.
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

    /// INSERT — fails on UNIQUE(`path`) conflict (the user tries to add an
    /// already-watched folder). The caller handles the GRDB DatabaseError SQLITE_CONSTRAINT.
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

    /// DELETE by `id`. No-op if the row does not exist (idempotent — the UI can
    /// safely call it multiple times).
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

    /// Partial UPDATE. A `nil` parameter — the field is left unchanged. `updated_ms` — bumped always
    /// on any change (audit trail). No-op if both `enabled` and `maxGranularity` are nil.
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

    // MARK: - Browser Domain Allow-list (Phase Track-6 P3)

    /// Returns all rows ordered by `added_at_ms` ASC (stable UI order).
    public func listBrowserDomainAllow() throws -> [(domain: String, granularity: URLGranularity, addedAtMs: Int64, notes: String?)] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(Schema.BrowserDomainAllow.domain),
                       \(Schema.BrowserDomainAllow.granularity),
                       \(Schema.BrowserDomainAllow.addedAtMs),
                       \(Schema.BrowserDomainAllow.notes)
                FROM \(Schema.BrowserDomainAllow.tableName)
                ORDER BY \(Schema.BrowserDomainAllow.addedAtMs) ASC
            """)
            return rows.compactMap { row -> (domain: String, granularity: URLGranularity, addedAtMs: Int64, notes: String?)? in
                guard let domain = row[Schema.BrowserDomainAllow.domain] as String?,
                      let granStr = row[Schema.BrowserDomainAllow.granularity] as String?,
                      let gran = URLGranularity(rawValue: granStr) else { return nil }
                let addedAtMs = (row[Schema.BrowserDomainAllow.addedAtMs] as Int64?) ?? 0
                let notes = row[Schema.BrowserDomainAllow.notes] as String?
                return (domain: domain, granularity: gran, addedAtMs: addedAtMs, notes: notes)
            }
        }
    }

    /// UPSERT — adds or replaces an entry for `domain`. Writer-only.
    public func upsertBrowserDomainAllow(domain: String, granularity: URLGranularity, notes: String?) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO \(Schema.BrowserDomainAllow.tableName) (
                    \(Schema.BrowserDomainAllow.domain),
                    \(Schema.BrowserDomainAllow.granularity),
                    \(Schema.BrowserDomainAllow.addedAtMs),
                    \(Schema.BrowserDomainAllow.notes)
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT(\(Schema.BrowserDomainAllow.domain)) DO UPDATE SET
                    \(Schema.BrowserDomainAllow.granularity) = excluded.\(Schema.BrowserDomainAllow.granularity),
                    \(Schema.BrowserDomainAllow.notes) = excluded.\(Schema.BrowserDomainAllow.notes)
                """,
                arguments: [domain, granularity.rawValue, nowMs, notes]
            )
        }
    }

    /// DELETE by `domain`. Idempotent — no-op if missing.
    public func removeBrowserDomainAllow(domain: String) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try db.execute(
                sql: "DELETE FROM \(Schema.BrowserDomainAllow.tableName) WHERE \(Schema.BrowserDomainAllow.domain) = ?",
                arguments: [domain]
            )
        }
    }

    // MARK: - Integrations (Phase 4.1)

    /// UPSERT one integration row keyed by `provider`. Writer-only.
    /// Single-row-per-provider — reconnecting the same workspace or
    /// switching to another workspace of the same provider simply overwrites the row.
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

    /// Returns row keyed by `provider`, or nil if not connected yet.
    /// Reader API — App consumes it during Settings UI rehydration, MCP/collector
    /// (Phase 4.2) — for polling auth.
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

    /// DELETE by `provider`. Idempotent — no-op for a missing row.
    /// "Disconnect" in the UI; the refresh flow also calls it on `invalid_grant`.
    public func deleteIntegration(provider: IntegrationProvider) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try db.execute(
                sql: "DELETE FROM \(Schema.Integrations.tableName) WHERE \(Schema.Integrations.provider) = ?",
                arguments: [provider.rawValue]
            )
        }
    }

    // MARK: - Workspace (Phase 5.1.B + Track-5 S2)

    /// UPSERT by `id`. Idempotency of creation + updates to `name` /
    /// `created_by_member_id` / `left_at_ms` rely on UPSERT semantics.
    /// Track-5 S2: renamed from `upsertOrg` and threads `left_at_ms` column.
    public func upsertWorkspace(_ workspace: Workspace) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO \(Schema.Workspaces.tableName) (
                    \(Schema.Workspaces.id),
                    \(Schema.Workspaces.name),
                    \(Schema.Workspaces.createdAtMs),
                    \(Schema.Workspaces.createdByMemberID),
                    \(Schema.Workspaces.leftAtMs)
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(\(Schema.Workspaces.id)) DO UPDATE SET
                    \(Schema.Workspaces.name)              = excluded.\(Schema.Workspaces.name),
                    \(Schema.Workspaces.createdAtMs)       = excluded.\(Schema.Workspaces.createdAtMs),
                    \(Schema.Workspaces.createdByMemberID) = excluded.\(Schema.Workspaces.createdByMemberID),
                    \(Schema.Workspaces.leftAtMs)          = excluded.\(Schema.Workspaces.leftAtMs)
                """,
                arguments: [
                    workspace.id,
                    workspace.name,
                    Int64(workspace.createdAt.timeIntervalSince1970 * 1000),
                    workspace.createdByMemberID,
                    workspace.leftAt.map { Int64($0.timeIntervalSince1970 * 1000) }
                ]
            )
        }
    }

    /// Returns the workspace row by id, regardless of `left_at_ms` /
    /// `deleted_at_ms` state.
    /// Track-5 S2: replaces `readOrg()` single-row lookup.
    public func readWorkspace(id: String) throws -> Workspace? {
        try pool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT \(Schema.Workspaces.id), \(Schema.Workspaces.name),
                       \(Schema.Workspaces.createdAtMs), \(Schema.Workspaces.createdByMemberID),
                       \(Schema.Workspaces.leftAtMs), \(Schema.Workspaces.deletedAtMs)
                FROM \(Schema.Workspaces.tableName)
                WHERE \(Schema.Workspaces.id) = ?
                LIMIT 1
                """,
                arguments: [id]
            )
            return row.flatMap(Self.mapWorkspaceRow)
        }
    }

    /// Lists workspaces ordered by `created_at_ms` ASC.
    /// `includeLeft: false` (default) filters out soft-marked rows where
    /// `left_at_ms IS NOT NULL` (OQ-T5-2 — UI hides from active list) and
    /// admin-deleted rows where `deleted_at_ms IS NOT NULL` (M025 / E.2).
    public func listWorkspaces(includeLeft: Bool = false) throws -> [Workspace] {
        try pool.read { db in
            let filter = includeLeft
                ? ""
                : " WHERE \(Schema.Workspaces.leftAtMs) IS NULL AND \(Schema.Workspaces.deletedAtMs) IS NULL"
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(Schema.Workspaces.id), \(Schema.Workspaces.name),
                       \(Schema.Workspaces.createdAtMs), \(Schema.Workspaces.createdByMemberID),
                       \(Schema.Workspaces.leftAtMs), \(Schema.Workspaces.deletedAtMs)
                FROM \(Schema.Workspaces.tableName)\(filter)
                ORDER BY \(Schema.Workspaces.createdAtMs) ASC
                """)
            return rows.compactMap(Self.mapWorkspaceRow)
        }
    }

    /// Soft-marks a workspace left: sets `left_at_ms = at`. Idempotent re-call
    /// on already-left row is a no-op (silent). Throws `.invalidPayload` if the
    /// workspace row does not exist. Track-5 S2 OQ-T5-2 — used by
    /// `WorkspaceService.markLeft` (Task 11).
    public func markWorkspaceLeft(workspaceID: String, at leftAt: Date) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try db.execute(sql: """
                UPDATE \(Schema.Workspaces.tableName)
                SET \(Schema.Workspaces.leftAtMs) = ?
                WHERE \(Schema.Workspaces.id) = ?
                  AND \(Schema.Workspaces.leftAtMs) IS NULL
                """,
                arguments: [
                    Int64(leftAt.timeIntervalSince1970 * 1000),
                    workspaceID
                ]
            )
            if db.changesCount == 1 { return }

            // changesCount == 0: either already-left (idempotent no-op) or missing row.
            let row = try Row.fetchOne(db, sql: """
                SELECT \(Schema.Workspaces.leftAtMs)
                FROM \(Schema.Workspaces.tableName)
                WHERE \(Schema.Workspaces.id) = ?
                LIMIT 1
                """,
                arguments: [workspaceID]
            )
            guard row != nil else { throw LeafError.invalidPayload }
        }
    }

    /// Clears `left_at_ms = NULL`. Used by `WorkspaceService.rejoin` (Task 11).
    /// Idempotent — no-op if workspace already active or missing.
    public func clearWorkspaceLeftAt(workspaceID: String) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try db.execute(sql: """
                UPDATE \(Schema.Workspaces.tableName)
                SET \(Schema.Workspaces.leftAtMs) = NULL
                WHERE \(Schema.Workspaces.id) = ?
                """,
                arguments: [workspaceID]
            )
        }
    }

    /// Track-5 S7 E.1 — Updates workspace display name. Idempotent (UPDATE
    /// WHERE id=? matches 0 rows on unknown workspace — no error).
    /// Caller (`WorkspaceService.updateName`) has already validated and trimmed
    /// the name; this helper just persists it.
    public func updateWorkspaceName(workspaceID: String, name: String) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try db.execute(sql: """
                UPDATE \(Schema.Workspaces.tableName)
                SET \(Schema.Workspaces.name) = ?
                WHERE \(Schema.Workspaces.id) = ?
                """,
                arguments: [name, workspaceID]
            )
        }
    }

    /// Strict INSERT — re-inserting the same UUID is a bug (the caller controls
    /// the PK). Idempotency of workspace+self-row creation is on the caller (5.1.D
    /// `OrgService.createPersonalOrg` checks `listWorkspaces()` first).
    public func insertTeamMember(_ member: TeamMember) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO \(Schema.TeamMembers.tableName) (
                    \(Schema.TeamMembers.id),
                    \(Schema.TeamMembers.workspaceID),
                    \(Schema.TeamMembers.role),
                    \(Schema.TeamMembers.pubkeyHex),
                    \(Schema.TeamMembers.displayName),
                    \(Schema.TeamMembers.addedAtMs),
                    \(Schema.TeamMembers.removedAtMs)
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    member.id,
                    member.workspaceID,
                    member.role.rawValue,
                    member.pubkeyHex,
                    member.displayName,
                    Int64(member.addedAt.timeIntervalSince1970 * 1000),
                    member.removedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
                ]
            )
        }
    }

    /// Returns members of a single workspace, ordered by `added_at_ms` ASC.
    /// `includeRemoved: false` (default) — active members only via the partial
    /// index `team_members_workspace_active`. UI Team list — default call.
    /// Track-5 S2: `orgID:` parameter label renamed → `workspaceID:`.
    public func readTeamMembers(workspaceID: String, includeRemoved: Bool = false) throws -> [TeamMember] {
        try pool.read { db in
            let sql = """
                SELECT \(Schema.TeamMembers.id), \(Schema.TeamMembers.workspaceID),
                       \(Schema.TeamMembers.role), \(Schema.TeamMembers.pubkeyHex),
                       \(Schema.TeamMembers.displayName), \(Schema.TeamMembers.addedAtMs),
                       \(Schema.TeamMembers.removedAtMs)
                FROM \(Schema.TeamMembers.tableName)
                WHERE \(Schema.TeamMembers.workspaceID) = ?\
                \(includeRemoved ? "" : " AND \(Schema.TeamMembers.removedAtMs) IS NULL")
                ORDER BY \(Schema.TeamMembers.addedAtMs) ASC
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [workspaceID])
            return rows.compactMap(Self.mapTeamMemberRow)
        }
    }

    /// Strict INSERT — each rotation is a unique row (history forever-retained,
    /// contract §12). UUID PK collision = bug. Track-5 S2: persists `workspace_id`
    /// from the `TeamKey` value (M019 backfilled column).
    public func insertTeamKey(_ key: TeamKey) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO \(Schema.TeamKeys.tableName) (
                    \(Schema.TeamKeys.id),
                    \(Schema.TeamKeys.workspaceID),
                    \(Schema.TeamKeys.generatedAtMs),
                    \(Schema.TeamKeys.deprecatedAtMs),
                    \(Schema.TeamKeys.generatedByMemberID)
                ) VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    key.id,
                    key.workspaceID,
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
                    \(Schema.TeamKeys.workspaceID),
                    \(Schema.TeamKeys.generatedAtMs),
                    \(Schema.TeamKeys.deprecatedAtMs),
                    \(Schema.TeamKeys.generatedByMemberID)
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(\(Schema.TeamKeys.id)) DO NOTHING
                """,
                arguments: [
                    key.id,
                    key.workspaceID,
                    Int64(key.generatedAt.timeIntervalSince1970 * 1000),
                    key.deprecatedAt.map { Int64($0.timeIntervalSince1970 * 1000) },
                    key.generatedByMemberID
                ]
            )
        }
    }

    /// Returns latest active rotation for the given workspace (`deprecated_at_ms IS NULL`
    /// scoped by `workspace_id`). ORDER+LIMIT — defensive against the edge case of "two active
    /// rows" (normally 1 row, not constrained at the DB level by contract).
    /// Track-5 S2: now scoped by `workspaceID` parameter (M019).
    public func readActiveTeamKey(workspaceID: String) throws -> TeamKey? {
        try pool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT \(Schema.TeamKeys.id), \(Schema.TeamKeys.workspaceID),
                       \(Schema.TeamKeys.generatedAtMs),
                       \(Schema.TeamKeys.deprecatedAtMs), \(Schema.TeamKeys.generatedByMemberID)
                FROM \(Schema.TeamKeys.tableName)
                WHERE \(Schema.TeamKeys.workspaceID) = ?
                  AND \(Schema.TeamKeys.deprecatedAtMs) IS NULL
                ORDER BY \(Schema.TeamKeys.generatedAtMs) DESC
                LIMIT 1
                """,
                arguments: [workspaceID]
            )
            return row.flatMap(Self.mapTeamKeyRow)
        }
    }

    // MARK: - Team lifecycle (Phase 5.3.A)

    /// Soft-delete on a team_members row. Sets `removed_at_ms = at`. An idempotent
    /// re-call on an already-removed row preserves the original timestamp (silent no-op).
    /// Throws `LeafError.invalidPayload` if the member does not exist.
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

            // changesCount == 0: either already-removed (idempotent no-op) or missing row.
            let row = try Row.fetchOne(db, sql: """
                SELECT \(Schema.TeamMembers.removedAtMs)
                FROM \(Schema.TeamMembers.tableName)
                WHERE \(Schema.TeamMembers.id) = ?
                LIMIT 1
                """,
                arguments: [memberID]
            )
            guard row != nil else { throw LeafError.invalidPayload }
            // row exists with non-NULL removed_at_ms → idempotent no-op, return.
        }
    }

    /// Marks team_keys row deprecated. Sets `deprecated_at_ms = at`.
    /// **Sole-active-per-workspace invariant:** throws `LeafError.invalidPayload`
    /// if deprecating this key would leave 0 active rows within `workspaceID`.
    /// The caller (5.3.D KeyRotationService) must `insertTeamKey(new)` first in the
    /// same tx. An idempotent re-call on an already-deprecated row preserves the original
    /// timestamp. Throws `LeafError.invalidPayload` if the key does not exist.
    /// Track-5 S2: added `workspaceID` parameter so the invariant scopes per
    /// workspace (M019).
    public func deprecateTeamKey(workspaceID: String, keyID: String, at deprecatedAt: Date) throws {
        guard mode == .writer else { throw LeafError.databaseUnavailable }
        try pool.write { db in
            // Step 1 — sole-active-per-workspace invariant guard.
            let activeCount = try Int.fetchOne(db, sql: """
                SELECT count(*)
                FROM \(Schema.TeamKeys.tableName)
                WHERE \(Schema.TeamKeys.workspaceID) = ?
                  AND \(Schema.TeamKeys.deprecatedAtMs) IS NULL
                """,
                arguments: [workspaceID]
            ) ?? 0
            if activeCount <= 1 {
                let targetActive = try Int.fetchOne(db, sql: """
                    SELECT count(*)
                    FROM \(Schema.TeamKeys.tableName)
                    WHERE \(Schema.TeamKeys.id) = ?
                      AND \(Schema.TeamKeys.workspaceID) = ?
                      AND \(Schema.TeamKeys.deprecatedAtMs) IS NULL
                    """,
                    arguments: [keyID, workspaceID]
                ) ?? 0
                if targetActive == 1 {
                    // Target is the sole active row — deprecate would leave 0 active.
                    throw LeafError.invalidPayload
                }
                // Otherwise — the target is either already-deprecated (idempotent path)
                // or missing (handled by the zero-changesCount branch below).
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

            // changesCount == 0: either already-deprecated (idempotent no-op)
            // or missing row.
            let row = try Row.fetchOne(db, sql: """
                SELECT \(Schema.TeamKeys.deprecatedAtMs)
                FROM \(Schema.TeamKeys.tableName)
                WHERE \(Schema.TeamKeys.id) = ?
                LIMIT 1
                """,
                arguments: [keyID]
            )
            guard row != nil else { throw LeafError.invalidPayload }
            // row exists with non-NULL deprecated_at_ms → idempotent no-op.
        }
    }

    /// Returns team_keys row by id, regardless of deprecated status.
    /// Used by the Phase 5.3.E peer-side flow to decrypt an incoming snapshot
    /// under a previously-rotated keyID (forever-retained per contract §12).
    /// Reader-mode safe — read-only API without a mode guard.
    public func readTeamKey(byID id: String) throws -> TeamKey? {
        try pool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT \(Schema.TeamKeys.id), \(Schema.TeamKeys.workspaceID),
                       \(Schema.TeamKeys.generatedAtMs),
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
                    \(Schema.TeamKeys.workspaceID),
                    \(Schema.TeamKeys.generatedAtMs),
                    \(Schema.TeamKeys.deprecatedAtMs),
                    \(Schema.TeamKeys.generatedByMemberID)
                ) VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    newTeamKey.id,
                    newTeamKey.workspaceID,
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
                // initiate rotation from a state where the prior key is already deprecated/missing).
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
            // Track-5 S2: persists workspace_id from the row (M019 column).
            for row in outboxRows {
                try db.execute(sql: """
                    INSERT INTO \(Schema.RotationOutbox.tableName) (
                        \(Schema.RotationOutbox.peerPubkeyHex),
                        \(Schema.RotationOutbox.newKeyID),
                        \(Schema.RotationOutbox.workspaceID),
                        \(Schema.RotationOutbox.priorKeyID),
                        \(Schema.RotationOutbox.kind),
                        \(Schema.RotationOutbox.peerMemberID),
                        \(Schema.RotationOutbox.blob),
                        \(Schema.RotationOutbox.expiresAtMs),
                        \(Schema.RotationOutbox.createdAtMs),
                        \(Schema.RotationOutbox.postedAtMs)
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        row.peerPubkeyHex,
                        row.newKeyID,
                        row.workspaceID,
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
                    \(Schema.RotationOutbox.workspaceID),
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
              let workspaceID: String = row[Schema.RotationOutbox.workspaceID],
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
            workspaceID: workspaceID,
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

    /// Phase 4.5 — a one-time wipe of Linear events + cursor for the migration to
    /// per-action attribution. The old query `{updatedAt:{gt:$since}}` was
    /// workspace-wide and counted teammate updates as user actions; existing
    /// rows are contaminated. The caller (`LinearCollector.runOneTimeMigration`)
    /// guarantees idempotency via a UserDefaults flag.
    /// Returns `(eventsDeleted, offsetsDeleted)` for diagnostic logging.
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

    /// Phase 4.7.B-3 — derive top-N repos for bounded fan-out actions/runs polling.
    /// Returns "owner/repo" identifiers ordered by count of `gh_commit_pushed`
    /// events DESC since `sinceMs` (typically `now - 7 days`).
    /// Used by `GitHubCollector.performTick()` before `fetchActionsRunsForActor` —
    /// caps the per-tick HTTP cost at N calls (one per repo) and focuses on
    /// genuinely active repos. Empty result → no actions/runs HTTP call at all.
    /// Reader-mode safe (read-only). Returns repos in DESC order by push count.
    public func queryActiveGitHubRepos(sinceMs: Int64, limit: Int) throws -> [String] {
        guard limit > 0 else { return [] }
        return try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT json_extract(\(Schema.Events.payloadJSON), '$.repo') AS repo,
                       COUNT(*) AS c
                FROM \(Schema.Events.tableName)
                WHERE json_extract(\(Schema.Events.payloadJSON), '$.source') = 'github'
                  AND json_extract(\(Schema.Events.payloadJSON), '$.event_kind') = 'gh_commit_pushed'
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

    /// Phase Track-3 D2 — viewer-authored issue refs (`owner/repo#NN`) within
    /// `sinceMs` lookback, deduped by ref, ordered by `events.ts` DESC, limited
    /// to `limit`. Used by `GitHubWarmCollector` for bounded fan-out
    /// `fetchIssueReactions` calls (cap = `issueReactionsTopK`). Emission of
    /// `gh_issue_opened` already implies the viewer authored the issue
    /// (REST events feed is filtered to viewer's own events). Reader-mode safe.
    public func queryRecentViewerAuthoredIssues(sinceMs: Int64, limit: Int) throws -> [String] {
        guard limit > 0 else { return [] }
        return try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT json_extract(\(Schema.Events.payloadJSON), '$.repo') AS repo,
                       json_extract(\(Schema.Events.payloadJSON), '$.number') AS num,
                       MAX(\(Schema.Events.ts)) AS ts
                FROM \(Schema.Events.tableName)
                WHERE json_extract(\(Schema.Events.payloadJSON), '$.source') = 'github'
                  AND json_extract(\(Schema.Events.payloadJSON), '$.event_kind') = 'gh_issue_opened'
                  AND \(Schema.Events.ts) >= ?
                  AND json_extract(\(Schema.Events.payloadJSON), '$.repo') IS NOT NULL
                  AND json_extract(\(Schema.Events.payloadJSON), '$.number') IS NOT NULL
                  AND json_extract(\(Schema.Events.payloadJSON), '$.number') != ''
                GROUP BY repo, num
                ORDER BY ts DESC
                LIMIT ?
                """,
                arguments: [sinceMs, limit]
            )
            return rows.compactMap { row -> String? in
                guard
                    let repo = row["repo"] as String?,
                    let num = row["num"] as String?,
                    !num.isEmpty
                else { return nil }
                return "\(repo)#\(num)"
            }
        }
    }

    // MARK: - Slack collector helpers (Phase 4.4)

    /// Phase 4.4 B6 — a narrow summary for the latest Slack `huddle_state_change`
    /// context event. The collector does not need a full `RawEvent` reconstruction —
    /// it only compares `state` for transition detection.
    public struct SlackHuddleEventSummary: Sendable, Equatable {
        /// Raw API string ("in_a_huddle" / "default_unset" / etc) — the collector
        /// converts it to `SlackHuddleState` itself via `init(slackAPIString:)`,
        /// so that forward-compat with unknown values stays at a single callsite.
        public let state: String
        public let tsMs: Int64

        public init(state: String, tsMs: Int64) {
            self.state = state
            self.tsMs = tsMs
        }
    }

    /// Returns (state, ts_ms) of the latest slack huddle_state_change context event,
    /// or nil if there is none in the DB. Used by SlackCollector for transition
    /// detection. The filter on `signal_type='context'` + JSON1 `payload.source='slack'`
    /// + `payload.event_kind='slack_huddle_state_change'` excludes action events
    /// (message aggregates) and events from other providers.
    public func readLatestSlackHuddleEvent() throws -> SlackHuddleEventSummary? {
        try pool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT json_extract(\(Schema.Events.payloadJSON), '$.state') AS state,
                       \(Schema.Events.ts) AS ts_ms
                FROM \(Schema.Events.tableName)
                WHERE \(Schema.Events.signalType) = ?
                  AND json_extract(\(Schema.Events.payloadJSON), '$.source') = 'slack'
                  AND json_extract(\(Schema.Events.payloadJSON), '$.event_kind') = 'slack_huddle_state_change'
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

    private static func mapWorkspaceRow(_ row: Row) -> Workspace? {
        guard
            let id = row[Schema.Workspaces.id] as String?,
            let name = row[Schema.Workspaces.name] as String?,
            let createdAtMs = row[Schema.Workspaces.createdAtMs] as Int64?,
            let createdByMemberID = row[Schema.Workspaces.createdByMemberID] as String?
        else { return nil }
        let leftAtMs = row[Schema.Workspaces.leftAtMs] as Int64?
        let deletedAtMs = row[Schema.Workspaces.deletedAtMs] as Int64?
        return Workspace(
            id: id,
            name: name,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAtMs) / 1000.0),
            createdByMemberID: createdByMemberID,
            leftAt: leftAtMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) },
            deletedAt: deletedAtMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
        )
    }

    private static func mapTeamMemberRow(_ row: Row) -> TeamMember? {
        guard
            let id = row[Schema.TeamMembers.id] as String?,
            let workspaceID = row[Schema.TeamMembers.workspaceID] as String?,
            let roleRaw = row[Schema.TeamMembers.role] as String?,
            let role = TeamMemberRole(rawValue: roleRaw),
            let pubkeyHex = row[Schema.TeamMembers.pubkeyHex] as String?,
            let displayName = row[Schema.TeamMembers.displayName] as String?,
            let addedAtMs = row[Schema.TeamMembers.addedAtMs] as Int64?
        else { return nil }
        let removedAtMs = row[Schema.TeamMembers.removedAtMs] as Int64?
        return TeamMember(
            id: id,
            workspaceID: workspaceID,
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
            let workspaceID = row[Schema.TeamKeys.workspaceID] as String?,
            let generatedAtMs = row[Schema.TeamKeys.generatedAtMs] as Int64?,
            let generatedByMemberID = row[Schema.TeamKeys.generatedByMemberID] as String?
        else { return nil }
        let deprecatedAtMs = row[Schema.TeamKeys.deprecatedAtMs] as Int64?
        return TeamKey(
            id: id,
            workspaceID: workspaceID,
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

    // MARK: - Test/diagnostic helpers (Track-5 S2)

    /// Returns column names of `tableName` via `PRAGMA table_info`. Used by
    /// schema-shape tests (M019 fresh / backfill / idempotency).
    public func fetchTableColumns(_ tableName: String) throws -> [String] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(tableName))")
            return rows.compactMap { $0["name"] as String? }
        }
    }

    /// Returns index names attached to `tableName` via `PRAGMA index_list`.
    public func fetchTableIndexes(_ tableName: String) throws -> [String] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA index_list(\(tableName))")
            return rows.compactMap { $0["name"] as String? }
        }
    }

    /// True if `tableName` is registered in `sqlite_master` as type='table'.
    public func tableExists(_ tableName: String) throws -> Bool {
        try pool.read { db in
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?
                """, arguments: [tableName]) ?? 0
            return count > 0
        }
    }

    // MARK: - Helpers

    private static func ensureDirectory(for url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Installs a `prepareDatabase` hook on the GRDB Configuration that applies
    /// SQLCipher pragmas per-connection. Ordering: pre-key → `PRAGMA key = x'HEX'` → post-key.
    /// If `opts == nil` — do nothing, the DB opens as plaintext SQLite.
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

    /// Detection + rename of plaintext SQLite on the first encrypted boot.
    /// Runs only in writer mode (the user already wrote → there is something to migrate),
    /// and only if encryption is passed (nil = stay on plaintext).
    /// Strategy (D-1.5-2): if the first 16 bytes == "SQLite format 3\0" → rename
    /// to `events.sqlite.pre-sqlcipher.bak`, delete the WAL/SHM sidecars, run the
    /// normal open flow (creates a fresh encrypted one).
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

    /// One-shot purge of a stale plaintext-to-encrypted migration backup
    /// (`events.sqlite.pre-sqlcipher.bak`). The backup is a recovery net created by
    /// `migrateFromPlaintextIfNeeded`; once the encrypted DB is healthy it is just
    /// plaintext user data lingering on disk, so delete it after `maxAge`. Called
    /// from `openForWrite` (writer process only → no multi-process race). Best-effort,
    /// logged at info. `now`/`maxAge` injectable for tests.
    static func purgeStalePlaintextBackupIfNeeded(
        at dbURL: URL,
        now: Date = Date(),
        maxAge: TimeInterval = 30 * 24 * 60 * 60
    ) {
        let backup = dbURL.appendingPathExtension("pre-sqlcipher.bak")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: backup.path),
            let mtime = attrs[.modificationDate] as? Date,
            now.timeIntervalSince(mtime) > maxAge
        else { return }
        try? FileManager.default.removeItem(at: backup)
        Logger(subsystem: "tech.gundem.leaf.core", category: "db")
            .info("Purged stale plaintext backup at \(backup.path, privacy: .public)")
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
