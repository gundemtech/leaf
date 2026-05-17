// Shared mock provider + fixture helpers for LinearCollector*Tests files.
// Split from LinearCollectorTests.swift for type_body_length / file_length.

import XCTest
import os

// Track-3 D1 — selective GRDB import to avoid `Database` symbol collision
// with `LeafCore.Database` in test helpers (e.g. `insertFreshIntegration(db: Database)`).
// Importing only `Row` keeps `Row.fetchOne/fetchAll` available without bringing
// in GRDB.Database as an ambiguous candidate at type-position.
import class GRDB.Row

@testable import LeafCore

enum LinearCollectorTestSupport {
    static let logger = Logger(subsystem: "tech.gundem.leaf.tests", category: "linear-collector")

    /// Captures `since` argument для assertion в тестах. Каждый `setBatch(_:)`
    /// заменяет следующий return value.
    actor MockLinearGraphQLProvider: LinearGraphQLProvider {
        private(set) var sinceCalls: [Int64?] = []
        private var batchToReturn: LinearIssueBatch = .empty

        func fetchIssues(accessToken: String, since: Int64?) async throws -> LinearIssueBatch {
            sinceCalls.append(since)
            return batchToReturn
        }

        // Track-3 D1: stub for protocol surface; not exercised by hot-tier tests.
        func fetchWarmState(accessToken: String, cursors: LinearWarmCursors) async throws -> LinearWarmBatch {
            .empty
        }

        // Track-3 D1: stub for protocol surface; not exercised by hot-tier tests.
        func fetchColdState(accessToken: String) async throws -> LinearColdBatch {
            .empty
        }

        func setBatch(_ batch: LinearIssueBatch) {
            self.batchToReturn = batch
        }

        func calls() -> [Int64?] { sinceCalls }
    }

    static func makeIsolatedSuiteName() -> String {
        "leaf-test-\(UUID().uuidString)"
    }

    static func insertFreshIntegration(
        db: Database,
        workspaceID: String = "ws-1",
        expiresAt: Date = Date().addingTimeInterval(3600)
    ) throws {
        let record = IntegrationRecord(
            provider: .linear,
            workspaceID: workspaceID,
            workspaceName: "Test Workspace",
            accessToken: "test-token",
            refreshToken: "refresh-token",
            expiresAt: expiresAt,
            scope: "read",
            connectedAt: Date(),
            updatedAt: Date()
        )
        try db.upsertIntegration(record)
    }
}
