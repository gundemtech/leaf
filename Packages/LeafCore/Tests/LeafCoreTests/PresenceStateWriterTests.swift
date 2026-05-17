// Phase 4.7.B B-0 — `PresenceStateWriter` UPSERT helper.
// Single point of write для presence_state; collector ticks выкручивают через
// него current-state snapshot. Тесты покрывают:
//   - happy path INSERT/UPDATE по PK provider,
//   - reader API (read / readAll) с roundtrip словарей,
//   - delete на disconnect,
//   - derived_mode null-инвариант (Phase 4.9 starts populating),
//   - boundary: caller передаёт "body" key — writer его не трогает (ADR-010
//     enforcement живёт upstream в каждом collector'е),
//   - атомарность writeEventsOffsetAndPresence: ошибка при сериализации
//     state не должна оставить partial state (нет events, нет offset, нет
//     presence row).

import GRDB
import XCTest

@testable import LeafCore

final class PresenceStateWriterTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-presence-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - upsert

    func testUpsertInsertsNewRow() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let nowMs: Int64 = 1_700_000_000_000
        try db.readSQL { rawDB in
            // Sanity — пустая таблица.
            let countBefore = try Int.fetchOne(
                rawDB,
                sql: "SELECT count(*) FROM \(Schema.PresenceState.tableName)"
            )
            XCTAssertEqual(countBefore, 0)
        }

        try writeInPool(db) { rawDB in
            try PresenceStateWriter.upsert(
                provider: .github,
                state: ["status": "online", "open_prs": 3],
                derivedMode: nil,
                nowMs: nowMs,
                in: rawDB
            )
        }

        try db.readSQL { rawDB in
            let count = try Int.fetchOne(
                rawDB,
                sql: "SELECT count(*) FROM \(Schema.PresenceState.tableName)"
            )
            XCTAssertEqual(count, 1)

            let row = try XCTUnwrap(
                try Row.fetchOne(
                    rawDB,
                    sql: "SELECT * FROM \(Schema.PresenceState.tableName) WHERE \(Schema.PresenceState.provider) = ?",
                    arguments: ["github"]
                ))
            XCTAssertEqual(row[Schema.PresenceState.provider] as String?, "github")
            XCTAssertEqual(row[Schema.PresenceState.updatedAtMs] as Int64?, nowMs)
            XCTAssertNil(row[Schema.PresenceState.derivedMode] as String?)
            // sortedKeys ⇒ детерминированная raw-форма.
            XCTAssertEqual(
                row[Schema.PresenceState.stateJSON] as String?,
                #"{"open_prs":3,"status":"online"}"#
            )
        }
    }

    func testUpsertUpdatesExistingRow() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let firstWrite: Int64 = 1_700_000_000_000
        let secondWrite: Int64 = 1_700_000_300_000

        try writeInPool(db) { rawDB in
            try PresenceStateWriter.upsert(
                provider: .github,
                state: ["status": "online"],
                derivedMode: nil,
                nowMs: firstWrite,
                in: rawDB
            )
        }
        try writeInPool(db) { rawDB in
            try PresenceStateWriter.upsert(
                provider: .github,
                state: ["status": "away"],
                derivedMode: nil,
                nowMs: secondWrite,
                in: rawDB
            )
        }

        try db.readSQL { rawDB in
            let count = try Int.fetchOne(
                rawDB,
                sql: "SELECT count(*) FROM \(Schema.PresenceState.tableName)"
            )
            XCTAssertEqual(count, 1, "PK conflict должен схлопнуть в один row")

            let row = try XCTUnwrap(
                try Row.fetchOne(
                    rawDB,
                    sql: "SELECT * FROM \(Schema.PresenceState.tableName)"
                ))
            XCTAssertEqual(row[Schema.PresenceState.updatedAtMs] as Int64?, secondWrite)
            XCTAssertEqual(
                row[Schema.PresenceState.stateJSON] as String?,
                #"{"status":"away"}"#
            )
        }
    }

    // MARK: - read / readAll

    func testReadReturnsLatestState() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try writeInPool(db) { rawDB in
            try PresenceStateWriter.upsert(
                provider: .linear,
                state: [
                    "assigned_count": 7,
                    "active_cycle": "Cycle 23",
                    "is_in_focus": true,
                ],
                derivedMode: nil,
                nowMs: 1_700_000_000_000,
                in: rawDB
            )
        }

        let result = try db.readSQL { rawDB -> (state: [String: Any], derivedMode: String?, updatedAtMs: Int64)? in
            try PresenceStateWriter.read(provider: .linear, in: rawDB)
        }

        let unwrapped = try XCTUnwrap(result)
        XCTAssertEqual(unwrapped.updatedAtMs, 1_700_000_000_000)
        XCTAssertNil(unwrapped.derivedMode)
        XCTAssertEqual(unwrapped.state["assigned_count"] as? Int, 7)
        XCTAssertEqual(unwrapped.state["active_cycle"] as? String, "Cycle 23")
        XCTAssertEqual(unwrapped.state["is_in_focus"] as? Bool, true)

        // Несуществующий provider → nil.
        let missing = try db.readSQL { rawDB -> (state: [String: Any], derivedMode: String?, updatedAtMs: Int64)? in
            try PresenceStateWriter.read(provider: .slack, in: rawDB)
        }
        XCTAssertNil(missing)
    }

    func testReadAllReturnsAllProviders() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try writeInPool(db) { rawDB in
            try PresenceStateWriter.upsert(
                provider: .github,
                state: ["k": "v_gh"],
                derivedMode: nil,
                nowMs: 1_700_000_001_000,
                in: rawDB
            )
            try PresenceStateWriter.upsert(
                provider: .linear,
                state: ["k": "v_lin"],
                derivedMode: nil,
                nowMs: 1_700_000_002_000,
                in: rawDB
            )
            try PresenceStateWriter.upsert(
                provider: .slack,
                state: ["k": "v_slack"],
                derivedMode: nil,
                nowMs: 1_700_000_003_000,
                in: rawDB
            )
        }

        let all = try db.readSQL { rawDB in
            try PresenceStateWriter.readAll(in: rawDB)
        }

        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[.github]?.state["k"] as? String, "v_gh")
        XCTAssertEqual(all[.linear]?.state["k"] as? String, "v_lin")
        XCTAssertEqual(all[.slack]?.state["k"] as? String, "v_slack")
        XCTAssertNil(all[.derived])
    }

    // MARK: - delete

    func testDeleteRemovesRow() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try writeInPool(db) { rawDB in
            try PresenceStateWriter.upsert(
                provider: .github,
                state: ["status": "online"],
                derivedMode: nil,
                nowMs: 1_700_000_000_000,
                in: rawDB
            )
        }
        try writeInPool(db) { rawDB in
            try PresenceStateWriter.delete(provider: .github, in: rawDB)
        }

        let all = try db.readSQL { rawDB in
            try PresenceStateWriter.readAll(in: rawDB)
        }
        XCTAssertEqual(all.count, 0)

        // Idempotent — повторный delete не падает.
        try writeInPool(db) { rawDB in
            try PresenceStateWriter.delete(provider: .github, in: rawDB)
        }
    }

    // MARK: - derivedMode invariant

    func testDerivedModeAlwaysNullInPhase47() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try writeInPool(db) { rawDB in
            try PresenceStateWriter.upsert(
                provider: .github,
                state: ["status": "online"],
                // derivedMode опускаем — defaults to nil; Phase 4.9 начнёт populate.
                nowMs: 1_700_000_000_000,
                in: rawDB
            )
        }

        let result = try db.readSQL { rawDB -> (state: [String: Any], derivedMode: String?, updatedAtMs: Int64)? in
            try PresenceStateWriter.read(provider: .github, in: rawDB)
        }
        XCTAssertNil(try XCTUnwrap(result).derivedMode)
    }

    // MARK: - ADR-010 boundary

    /// Defensive test: writer не магически вырезает потенциально-чувствительные
    /// ключи из state dict. Очистка от bodies/titles/PII живёт upstream в
    /// каждом провайдере (LinearGraphQLProvider / GitHubAPIProvider /
    /// SlackAPIProvider), здесь мы только убеждаемся, что boundary не
    /// сдвинулась — иначе test упадёт и заставит обновить контракт.
    func testStateJSONRedactionRespected() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        // Caller "забыл" применить redaction и положил поле "body" — это
        // ошибка caller'а, но writer её не маскирует.
        try writeInPool(db) { rawDB in
            try PresenceStateWriter.upsert(
                provider: .slack,
                state: ["body": "PRIVATE_LEAK", "channel": "general"],
                derivedMode: nil,
                nowMs: 1_700_000_000_000,
                in: rawDB
            )
        }

        let result = try db.readSQL { rawDB -> (state: [String: Any], derivedMode: String?, updatedAtMs: Int64)? in
            try PresenceStateWriter.read(provider: .slack, in: rawDB)
        }
        let state = try XCTUnwrap(result).state
        // "body" сохранён, как был передан — caller responsibility.
        XCTAssertEqual(state["body"] as? String, "PRIVATE_LEAK")
        XCTAssertEqual(state["channel"] as? String, "general")
    }

    // MARK: - atomicity

    /// Атомарность `writeEventsOffsetAndPresence`: если presence сериализация
    /// падает (non-JSON-serializable значение в state), вся транзакция
    /// откатывается — ни events, ни offset, ни presence row.
    /// `Date()` через JSONSerialization не сериализуется → throw перед
    /// любым `db.execute`. Verifies all-or-nothing invariant.
    func testWriteEventsOffsetAndPresenceAtomic() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let events = (0..<3).map { i in
            RawEvent(
                timestamp: base.addingTimeInterval(TimeInterval(i * 30)),
                signalType: .action,
                bundleID: "com.example",
                payload: ["event_kind": "gh_commit_pushed"]
            )
        }
        let offset = CollectorOffset(
            collectorID: CollectorID.githubPolling,
            sourceID: "github:demoffsrmain",
            byteOffset: 0,
            inode: nil,
            size: 0,
            lastModifiedMs: 1_700_000_500_000,
            updatedMs: 1_700_000_500_000
        )

        XCTAssertThrowsError(
            try db.writeEventsOffsetAndPresence(
                events,
                offset: offset,
                presence: (
                    provider: .github,
                    // Date — не JSON-serializable через JSONSerialization →
                    // upsert бросит .jsonEncodingFailed до db.execute.
                    state: ["bad": Date()],
                    derivedMode: nil
                ),
                nowMs: 1_700_000_500_000
            )
        ) { error in
            guard case LeafError.jsonEncodingFailed = error else {
                XCTFail("Expected .jsonEncodingFailed, got \(error)")
                return
            }
        }

        // Полный rollback: ни events, ни offset, ни presence row.
        let allEvents = try db.events(
            in: DateInterval(
                start: .distantPast,
                end: .distantFuture
            ))
        XCTAssertTrue(allEvents.isEmpty, "events не должны просочиться при failed presence write")

        let storedOffset = try db.readOffset(
            collectorID: CollectorID.githubPolling,
            sourceID: "github:demoffsrmain"
        )
        XCTAssertNil(storedOffset, "offset не должен advance при failed presence write")

        let presenceAll = try db.readSQL { rawDB in
            try PresenceStateWriter.readAll(in: rawDB)
        }
        XCTAssertEqual(presenceAll.count, 0)
    }

    /// Happy path для writeEventsOffsetAndPresence — sanity, что combined
    /// write реально пишет все три сущности атомарно.
    func testWriteEventsOffsetAndPresenceHappyPath() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [
            RawEvent(
                timestamp: base,
                signalType: .action,
                bundleID: "com.example",
                payload: ["event_kind": "gh_commit_pushed"]
            )
        ]
        let offset = CollectorOffset(
            collectorID: CollectorID.githubPolling,
            sourceID: "github:demoffsrmain",
            byteOffset: 0,
            inode: nil,
            size: 0,
            lastModifiedMs: 1_700_000_500_000,
            updatedMs: 1_700_000_500_000
        )

        try db.writeEventsOffsetAndPresence(
            events,
            offset: offset,
            presence: (
                provider: .github,
                state: ["status": "online", "open_prs": 2],
                derivedMode: nil
            ),
            nowMs: 1_700_000_500_000
        )

        let allEvents = try db.events(
            in: DateInterval(
                start: base.addingTimeInterval(-10),
                end: base.addingTimeInterval(86_400)
            ))
        XCTAssertEqual(allEvents.count, 1)

        let storedOffset = try db.readOffset(
            collectorID: CollectorID.githubPolling,
            sourceID: "github:demoffsrmain"
        )
        XCTAssertEqual(storedOffset?.lastModifiedMs, 1_700_000_500_000)

        let presence = try db.readSQL { rawDB in
            try PresenceStateWriter.read(provider: .github, in: rawDB)
        }
        XCTAssertEqual(try XCTUnwrap(presence).state["open_prs"] as? Int, 2)
    }

    // MARK: - Helpers

    /// Локальный helper: `Database.readSQL` readonly, поэтому здесь
    /// используем internal `writeSQL` bridge для прямого вызова
    /// `PresenceStateWriter.upsert` / `delete` в транзакции.
    private func writeInPool(_ db: LeafCore.Database, _ block: (GRDB.Database) throws -> Void) throws {
        try db.writeSQL(block)
    }
}
