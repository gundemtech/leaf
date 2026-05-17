import XCTest
import os

import class GRDB.Row

@testable import LeafCore

final class LinearColdCollectorTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private let logger = Logger(subsystem: "tech.gundem.leaf.tests", category: "cold")

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-cold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tempDir) }

    private actor MockProvider: LinearGraphQLProvider {
        private var nextCold: LinearColdBatch = .empty
        func setCold(_ b: LinearColdBatch) { nextCold = b }
        func fetchIssues(accessToken: String, since: Int64?) async throws -> LinearIssueBatch { .empty }
        func fetchWarmState(accessToken: String, cursors: LinearWarmCursors) async throws -> LinearWarmBatch { .empty }
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

    func testBootstrapEmitsOnlyRoadmapHeartbeats() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertIntegration(db)
        let p = MockProvider()
        await p.setCold(
            LinearColdBatch(
                roadmaps: [
                    LinearRoadmapSnapshot(
                        id: "r1", name: "RM1",
                        projects: [
                            .init(projectId: "pr1", projectName: "PRJ1", stateEnum: "onTrack"),
                            .init(projectId: "pr2", projectName: "PRJ2", stateEnum: "atRisk"),
                        ])
                ],
                customViews: [.init(id: "v1", name: "V1", teamId: nil, updatedAtMs: 1)],
                projectMemberships: [.init(projectId: "pr1", projectName: "PRJ1")]
            ))
        let c = LinearColdCollector(
            database: db, provider: p,
            refresher: LinearTokenRefresher(database: db, clientID: "cid"),
            logger: logger
        )
        let r = await c.performTick()
        XCTAssertEqual(r.eventsEmitted, 2, "Bootstrap: roadmap heartbeats only (2 pairs)")
        // All 3 snapshots must now exist.
        try db.readSQL { raw in
            XCTAssertNotNil(
                try ProviderSnapshotsStore.read(
                    provider: "linear", snapshotKind: Schema.ProviderSnapshotKinds.linearCustomViews, in: raw))
            XCTAssertNotNil(
                try ProviderSnapshotsStore.read(
                    provider: "linear", snapshotKind: Schema.ProviderSnapshotKinds.linearProjectMemberships, in: raw))
            XCTAssertNotNil(
                try ProviderSnapshotsStore.read(
                    provider: "linear", snapshotKind: Schema.ProviderSnapshotKinds.linearRoadmapState, in: raw))
        }
    }

    func testSteadyStateCustomViewDiffEmissions() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertIntegration(db)
        // Seed prior snapshots.
        try db.writeSQL { raw in
            try ProviderSnapshotsStore.upsert(
                ProviderSnapshot(
                    provider: "linear",
                    snapshotKind: Schema.ProviderSnapshotKinds.linearCustomViews,
                    snapshotJSON:
                        "{\"views\":[{\"id\":\"v1\",\"name\":\"Old\",\"teamId\":null,\"updatedAtMs\":1},{\"id\":\"v2\",\"name\":\"V2\",\"teamId\":null,\"updatedAtMs\":1}]}",
                    capturedAtMs: 0), in: raw)
            try ProviderSnapshotsStore.upsert(
                ProviderSnapshot(
                    provider: "linear",
                    snapshotKind: Schema.ProviderSnapshotKinds.linearProjectMemberships,
                    snapshotJSON: "{\"memberships\":[]}", capturedAtMs: 0), in: raw)
        }
        let p = MockProvider()
        await p.setCold(
            LinearColdBatch(
                roadmaps: [],
                customViews: [
                    .init(id: "v1", name: "New", teamId: nil, updatedAtMs: 1),  // updated by name
                    .init(id: "v3", name: "V3", teamId: nil, updatedAtMs: 5),  // created
                    // v2 deleted (absent)
                ],
                projectMemberships: []
            ))
        let c = LinearColdCollector(
            database: db, provider: p,
            refresher: LinearTokenRefresher(database: db, clientID: "cid"),
            logger: logger)
        _ = await c.performTick()
        try db.readSQL { raw in
            let rows = try Row.fetchAll(raw, sql: "SELECT payload_json FROM events ORDER BY id ASC")
            let texts = rows.compactMap { $0["payload_json"] as String? }
            XCTAssertTrue(
                texts.contains { $0.contains("linear_custom_view_updated") && $0.contains("\"view_id\":\"v1\"") })
            XCTAssertTrue(
                texts.contains { $0.contains("linear_custom_view_created") && $0.contains("\"view_id\":\"v3\"") })
            XCTAssertTrue(
                texts.contains { $0.contains("linear_custom_view_deleted") && $0.contains("\"view_id\":\"v2\"") })
        }
    }

    func testColdOffsetAdvancesToNowMs() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertIntegration(db)
        let p = MockProvider()
        await p.setCold(.empty)
        let c = LinearColdCollector(
            database: db, provider: p,
            refresher: LinearTokenRefresher(database: db, clientID: "cid"),
            logger: logger)
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        _ = await c.performTick()
        let after = Int64(Date().timeIntervalSince1970 * 1000)
        let off = try db.readOffset(collectorID: CollectorID.linearColdPolling, sourceID: "linear:cold:w1")
        XCTAssertNotNil(off)
        XCTAssertGreaterThanOrEqual(off!.lastModifiedMs, before)
        XCTAssertLessThanOrEqual(off!.lastModifiedMs, after + 1000)
    }
}
