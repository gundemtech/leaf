import XCTest
import os

import class GRDB.Row

@testable import LeafCore

final class LinearWarmCollectorTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private let logger = Logger(subsystem: "tech.gundem.leaf.tests", category: "warm")

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-warm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tempDir) }

    private actor MockProvider: LinearGraphQLProvider {
        private var nextWarm: LinearWarmBatch = .empty
        private var nextCold: LinearColdBatch = .empty
        func setWarm(_ b: LinearWarmBatch) { nextWarm = b }
        func setCold(_ b: LinearColdBatch) { nextCold = b }
        func fetchIssues(accessToken: String, since: Int64?) async throws -> LinearIssueBatch { .empty }
        func fetchWarmState(accessToken: String, cursors: LinearWarmCursors) async throws -> LinearWarmBatch {
            nextWarm
        }
        func fetchColdState(accessToken: String) async throws -> LinearColdBatch { nextCold }
    }

    private func insertIntegration(_ db: Database) throws {
        try db.upsertIntegration(
            IntegrationRecord(
                provider: .linear, workspaceID: "w1", workspaceName: "WS",
                accessToken: "t", refreshToken: "r",
                expiresAt: Date().addingTimeInterval(3600), scope: "read",
                connectedAt: Date(), updatedAt: Date()))
    }

    private func makeCollector(_ db: Database, _ provider: MockProvider) -> LinearWarmCollector {
        LinearWarmCollector(
            database: db, provider: provider,
            refresher: LinearTokenRefresher(database: db, clientID: "cid"),
            intervalSec: 900, backfillWindowDays: 7, logger: logger
        )
    }

    func testSkipWhenNoIntegration() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let p = MockProvider()
        let c = makeCollector(db, p)
        let r = await c.performTick()
        XCTAssertTrue(r.skipped)
        XCTAssertEqual(r.eventsEmitted, 0)
    }

    func testBootstrapWritesSnapshotEmitsCycleEventsOnly() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertIntegration(db)
        let p = MockProvider()
        await p.setWarm(
            LinearWarmBatch(
                notifications: [],
                notificationCursorMs: 1000,
                cyclesStarted: [
                    LinearCycleLifecycleSnapshot(
                        id: "cy-1", number: 1, teamId: "t-1", name: "Sprint 1",
                        startsAtMs: 500, endsAtMs: 1500,
                        completedAtMs: nil, progress: nil, issuesCompletedCount: nil
                    )
                ],
                cyclesCompleted: [],
                cyclesCursorMs: 1000,
                subscribedIssueIds: [LinearSubscribedIssueSnapshot(id: "i-1", identifier: "LEAF-1")]
            ))
        let c = makeCollector(db, p)
        let r = await c.performTick()
        XCTAssertFalse(r.skipped)
        XCTAssertEqual(r.eventsEmitted, 1, "Bootstrap: cycle event only, no subscription events")
        // Snapshot should now exist.
        try db.readSQL { raw in
            let s = try ProviderSnapshotsStore.read(
                provider: "linear", snapshotKind: Schema.ProviderSnapshotKinds.linearSubscribedIssues, in: raw)
            XCTAssertNotNil(s)
            XCTAssertTrue(s!.snapshotJSON.contains("\"i-1\""))
        }
    }

    func testSubscriptionDiffEmitsAddedRemoved() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertIntegration(db)
        // Seed prior snapshot.
        try db.writeSQL { raw in
            try ProviderSnapshotsStore.upsert(
                ProviderSnapshot(
                    provider: "linear",
                    snapshotKind: Schema.ProviderSnapshotKinds.linearSubscribedIssues,
                    snapshotJSON: "{\"ids\":[\"a\",\"b\"]}", capturedAtMs: 0
                ), in: raw)
        }
        let p = MockProvider()
        await p.setWarm(
            LinearWarmBatch(
                notifications: [], notificationCursorMs: nil,
                cyclesStarted: [], cyclesCompleted: [], cyclesCursorMs: nil,
                subscribedIssueIds: [
                    LinearSubscribedIssueSnapshot(id: "b", identifier: "LEAF-B"),
                    LinearSubscribedIssueSnapshot(id: "c", identifier: "LEAF-C"),
                ]
            ))
        let c = makeCollector(db, p)
        let r = await c.performTick()
        XCTAssertEqual(r.eventsEmitted, 2, "Expect 1 added (c) + 1 removed (a)")
        try db.readSQL { raw in
            let rows = try Row.fetchAll(raw, sql: "SELECT payload_json FROM events ORDER BY id ASC")
            let texts = rows.compactMap { $0["payload_json"] as String? }
            XCTAssertTrue(texts.contains { $0.contains("\"event_kind\":\"linear_subscription_added\"") })
            XCTAssertTrue(texts.contains { $0.contains("\"event_kind\":\"linear_subscription_removed\"") })
        }
    }

    func testNotificationCursorAdvancesOnPartialBatch() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertIntegration(db)
        let p = MockProvider()
        await p.setWarm(
            LinearWarmBatch(
                notifications: [
                    LinearNotificationSnapshot(
                        id: "n1", kind: "issueAssignedToYou",
                        issueId: "i1", issueIdentifier: "LEAF-1",
                        title: "Alice assigned LEAF-1 to you",
                        createdAtMs: 5000, readAtMs: nil, archivedAtMs: nil
                    )
                ],
                notificationCursorMs: 5000,
                cyclesStarted: [], cyclesCompleted: [],
                cyclesCursorMs: nil,  // cycles endpoint failed; cursor not advanced
                subscribedIssueIds: []
            ))
        let c = makeCollector(db, p)
        _ = await c.performTick()
        let notif = try db.readOffset(collectorID: CollectorID.linearWarmPolling, sourceID: "linear:notifications:w1")
        let cycles = try db.readOffset(collectorID: CollectorID.linearWarmPolling, sourceID: "linear:cycles:w1")
        XCTAssertEqual(notif?.lastModifiedMs, 5000, "Notifications cursor must advance")
        XCTAssertNil(cycles, "Cycles cursor must not advance when batch.cyclesCursorMs is nil")
    }

    func testProviderErrorEmitsZero() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertIntegration(db)
        struct ThrowingProvider: LinearGraphQLProvider {
            func fetchIssues(accessToken: String, since: Int64?) async throws -> LinearIssueBatch { .empty }
            func fetchWarmState(accessToken: String, cursors: LinearWarmCursors) async throws -> LinearWarmBatch {
                throw NSError(domain: "net", code: 503)
            }
            func fetchColdState(accessToken: String) async throws -> LinearColdBatch { .empty }
        }
        let c = LinearWarmCollector(
            database: db, provider: ThrowingProvider(),
            refresher: LinearTokenRefresher(database: db, clientID: "cid"),
            intervalSec: 900, backfillWindowDays: 7, logger: logger
        )
        let r = await c.performTick()
        XCTAssertFalse(r.skipped)
        XCTAssertEqual(r.eventsEmitted, 0)
    }
}
