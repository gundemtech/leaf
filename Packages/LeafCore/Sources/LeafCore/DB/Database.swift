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
