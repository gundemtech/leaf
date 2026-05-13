import XCTest
import os
@testable import LeafCore

final class MaintenanceSchedulerTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    private let logger = Logger(subsystem: "tech.gundem.leaf.tests", category: "maintenance")

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-maintenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - performRetentionSweep

    func testPerformRetentionSweepChunksUntilAllDeleted() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        // 12_000 old events, all below cutoff=1.
        let base = Date(timeIntervalSince1970: 0)
        let events = (0..<12_000).map { i in
            RawEvent(
                timestamp: base.addingTimeInterval(TimeInterval(i) * 0.0001),  // все ts < 2ms
                signalType: .attention,
                bundleID: "X"
            )
        }
        try db.write(events)

        let scheduler = MaintenanceScheduler(
            database: db,
            walCheckpointIntervalSec: 999,  // не триггерится в этом тесте
            retentionSweepIntervalSec: 999,
            retentionDays: 0,               // cutoff == nowMs
            chunkLimit: 5_000,
            logger: logger
        )

        await scheduler.performRetentionSweep(nowMs: Int64(Date().timeIntervalSince1970 * 1000))

        // All events must be gone (retentionDays=0 → cutoff == now → всё прошлое удалено).
        let remaining = try db.eventCount(in: DateInterval(
            start: Date(timeIntervalSince1970: -10),
            end: Date(timeIntervalSince1970: 10_000_000_000)
        ))
        XCTAssertEqual(remaining, 0)
    }

    // MARK: - Phase Track-4 S3 — intensity_aggregates retention

    func testPerformRetentionSweepPurgesIntensityAggregates() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        // Three rows at distinct minute buckets. Cutoff at retentionDays=0 ⇒
        // nowMs; expectation: all rows below that timestamp purged.
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        for offset in [Int64(-86_400_000), Int64(-43_200_000), Int64(-3_600_000)] {
            try db.upsertIntensityAggregate(
                minuteBucketMs: nowMs + offset,
                keystrokes: 1, mouseMoves: 1, appSwitches: 0,
                foregroundApp: "x"
            )
        }
        XCTAssertEqual(try db.readIntensityAggregates(range: 0..<Int64.max).count, 3)

        let scheduler = MaintenanceScheduler(
            database: db,
            walCheckpointIntervalSec: 999,
            retentionSweepIntervalSec: 999,
            retentionDays: 0,
            chunkLimit: 5_000,
            logger: logger
        )
        await scheduler.performRetentionSweep(nowMs: nowMs)

        XCTAssertEqual(
            try db.readIntensityAggregates(range: 0..<Int64.max).count, 0,
            "retentionDays=0 must purge all aggregates with bucket < nowMs"
        )
    }

    func testPerformRetentionSweepRespectsRetentionDays() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let dayMs = Int64(86_400_000)

        // 5 days old → outside 3d retention.
        try db.upsertIntensityAggregate(minuteBucketMs: nowMs - 5 * dayMs,
            keystrokes: 1, mouseMoves: 1, appSwitches: 0, foregroundApp: nil)
        // 1 day old → inside 3d retention.
        try db.upsertIntensityAggregate(minuteBucketMs: nowMs - 1 * dayMs,
            keystrokes: 2, mouseMoves: 2, appSwitches: 0, foregroundApp: nil)

        let scheduler = MaintenanceScheduler(
            database: db,
            walCheckpointIntervalSec: 999,
            retentionSweepIntervalSec: 999,
            retentionDays: 3,
            chunkLimit: 5_000,
            logger: logger
        )
        await scheduler.performRetentionSweep(nowMs: nowMs)

        let remaining = try db.readIntensityAggregates(range: 0..<Int64.max)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].minuteBucketMs, nowMs - 1 * dayMs)
    }

    // MARK: - performCheckpoint

    func testPerformCheckpointDoesNotThrow() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try db.write(RawEvent(signalType: .attention, bundleID: "X"))

        let scheduler = MaintenanceScheduler(
            database: db,
            walCheckpointIntervalSec: 999,
            retentionSweepIntervalSec: 999,
            retentionDays: 180,
            chunkLimit: 5_000,
            logger: logger
        )

        // performCheckpoint сам глотает ошибку — тест что await завершается без crash.
        await scheduler.performCheckpoint()
    }

    // MARK: - start/stop lifecycle

    func testStopIsPromptEvenWithLongInterval() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let scheduler = MaintenanceScheduler(
            database: db,
            walCheckpointIntervalSec: 3_600,       // час — не должен сработать
            retentionSweepIntervalSec: 3_600,      // час — половина = 30 мин first tick
            retentionDays: 180,
            chunkLimit: 5_000,
            logger: logger
        )

        await scheduler.start()
        // Even with hour-long intervals, stop() не должен ждать тика —
        // initial sleep прерывается через Task.cancel().
        let startTime = Date()
        await scheduler.stop()
        let elapsed = Date().timeIntervalSince(startTime)
        XCTAssertLessThan(elapsed, 1.0, "stop() должен возвращать < 1s (sleep cancel-aware)")
    }

    func testStartStopIsIdempotent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let scheduler = MaintenanceScheduler(
            database: db,
            walCheckpointIntervalSec: 3_600,
            retentionSweepIntervalSec: 3_600,
            retentionDays: 180,
            chunkLimit: 5_000,
            logger: logger
        )

        await scheduler.start()
        await scheduler.start()  // повторный start — no-op, не создаёт второй Task
        await scheduler.stop()
        await scheduler.stop()   // повторный stop — no-op
        // No crash → test passes.
    }
}
