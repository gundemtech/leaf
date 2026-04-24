import Foundation
import GRDB

/// Phase 1 plaintext GRDB 7.x wrapper. SQLCipher — отдельный sub-phase 1.5.
/// Writer (Agent) и Reader (App / MCP) — разные `Database` instance'ы поверх одного файла через WAL.
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

    public static func openForWrite(at url: URL, config: DatabaseConfig) throws -> Database {
        try ensureDirectory(for: url)

        var grdbConfig = Configuration()
        grdbConfig.readonly = false
        grdbConfig.busyMode = .timeout(TimeInterval(config.busyTimeoutMs) / 1000.0)

        let pool = try DatabasePool(path: url.path, configuration: grdbConfig)

        var migrator = DatabaseMigrator()
        migrator.registerMigration001Events()
        try migrator.migrate(pool)

        return Database(pool: pool, config: config, mode: .writer)
    }

    public static func openForRead(at url: URL, config: DatabaseConfig) throws -> Database {
        var grdbConfig = Configuration()
        grdbConfig.readonly = true
        grdbConfig.busyMode = .timeout(TimeInterval(config.busyTimeoutMs) / 1000.0)

        let pool = try DatabasePool(path: url.path, configuration: grdbConfig)
        return Database(pool: pool, config: config, mode: .reader)
    }

    // MARK: - Writes

    public func write(_ event: RawEvent) throws {
        guard mode == .writer else { throw LeafControlError.databaseUnavailable }

        let record = try EventRecord.make(from: event)

        try pool.write { db in
            var mutableRecord = record
            try mutableRecord.insert(db)
        }
    }

    public func write(_ events: [RawEvent]) throws {
        guard mode == .writer else { throw LeafControlError.databaseUnavailable }
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

    public func checkpointWAL() throws {
        guard mode == .writer else { throw LeafControlError.databaseUnavailable }
        try pool.writeWithoutTransaction { db in
            _ = try db.checkpoint(.truncate)
        }
    }

    /// Internal-intent bridge для LeafControlCorePrivate (moat-реализация
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
            throw LeafControlError.invalidPayload
        }

        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(ts) / 1000.0),
            signalType: signal,
            bundleID: bundleID,
            payload: payload
        )
    }
}
