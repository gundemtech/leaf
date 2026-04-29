// Phase 4.1 — public-side tests для integrations таблицы (M004) +
// 3 CRUD методов Database. LinearOAuthService unit-тестами не покрыт
// (Network.framework + URLSession + NSWorkspace.open — heavy mocking
// без выгоды; manual smoke в PR description).

import XCTest
import GRDB
@testable import LeafCore

final class DatabaseIntegrationsTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-integrations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Schema (M004)

    /// M004 создаёт таблицу с правильными колонками. PK на provider.
    func testMigrationCreatesTable() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let tables = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
                arguments: [Schema.Integrations.tableName]
            )
            XCTAssertEqual(tables, [Schema.Integrations.tableName])

            let columns = try Row.fetchAll(rawDB, sql: "PRAGMA table_info(\(Schema.Integrations.tableName))")
                .compactMap { $0["name"] as String? }
            XCTAssertTrue(columns.contains(Schema.Integrations.provider))
            XCTAssertTrue(columns.contains(Schema.Integrations.workspaceID))
            XCTAssertTrue(columns.contains(Schema.Integrations.workspaceName))
            XCTAssertTrue(columns.contains(Schema.Integrations.accessToken))
            XCTAssertTrue(columns.contains(Schema.Integrations.refreshToken))
            XCTAssertTrue(columns.contains(Schema.Integrations.expiresAtMs))
            XCTAssertTrue(columns.contains(Schema.Integrations.scope))
            XCTAssertTrue(columns.contains(Schema.Integrations.connectedAtMs))
            XCTAssertTrue(columns.contains(Schema.Integrations.updatedMs))
        }
    }

    // MARK: - upsert + read

    /// Базовый round-trip: upsert → read возвращает тот же row с правильно
    /// раскодированными датами + nil-fields.
    func testUpsertAndReadRoundTrip() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let connected = Date(timeIntervalSince1970: 1_700_000_000)
        let expires = Date(timeIntervalSince1970: 1_700_086_399)
        let record = IntegrationRecord(
            provider: .linear,
            workspaceID: "ws-123",
            workspaceName: "Acme Inc",
            accessToken: "tok-access",
            refreshToken: "tok-refresh",
            expiresAt: expires,
            scope: "read",
            connectedAt: connected,
            updatedAt: connected
        )
        try db.upsertIntegration(record)

        let loaded = try db.readIntegration(provider: .linear)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.provider, .linear)
        XCTAssertEqual(loaded?.workspaceID, "ws-123")
        XCTAssertEqual(loaded?.workspaceName, "Acme Inc")
        XCTAssertEqual(loaded?.accessToken, "tok-access")
        XCTAssertEqual(loaded?.refreshToken, "tok-refresh")
        XCTAssertEqual(loaded?.scope, "read")
        // 1ms precision floor от Int64(_ * 1000) round-trip.
        XCTAssertEqual(loaded?.connectedAt.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 0.001)
        XCTAssertEqual(loaded?.expiresAt?.timeIntervalSince1970 ?? 0, 1_700_086_399, accuracy: 0.001)
    }

    /// `refreshToken == nil` и `expiresAt == nil` сохраняются как NULL и
    /// корректно поднимаются обратно. Linear возвращает refresh_token, но
    /// для других provider'ов (на v1.1+) поле может быть пустым.
    func testUpsertHandlesNilOptionals() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try db.upsertIntegration(IntegrationRecord(
            provider: .linear,
            workspaceID: "ws-1",
            workspaceName: "Workspace",
            accessToken: "access",
            refreshToken: nil,
            expiresAt: nil,
            scope: "read",
            connectedAt: now,
            updatedAt: now
        ))

        let loaded = try db.readIntegration(provider: .linear)
        XCTAssertNotNil(loaded)
        XCTAssertNil(loaded?.refreshToken)
        XCTAssertNil(loaded?.expiresAt)
    }

    /// Single-row-per-provider — повторный upsert замещает row in-place.
    /// Reconnect flow: новый workspace под тем же provider'ом перезаписывает
    /// предыдущий, не плодит rows.
    func testUpsertReplacesExistingRow() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try db.upsertIntegration(IntegrationRecord(
            provider: .linear, workspaceID: "ws-1", workspaceName: "First",
            accessToken: "old-tok", refreshToken: "old-ref", expiresAt: nil,
            scope: "read", connectedAt: now, updatedAt: now
        ))

        let later = now.addingTimeInterval(3600)
        try db.upsertIntegration(IntegrationRecord(
            provider: .linear, workspaceID: "ws-2", workspaceName: "Second",
            accessToken: "new-tok", refreshToken: "new-ref", expiresAt: nil,
            scope: "read", connectedAt: later, updatedAt: later
        ))

        let loaded = try db.readIntegration(provider: .linear)
        XCTAssertEqual(loaded?.workspaceID, "ws-2")
        XCTAssertEqual(loaded?.workspaceName, "Second")
        XCTAssertEqual(loaded?.accessToken, "new-tok")

        // Один row total.
        try db.readSQL { rawDB in
            let count = try Int.fetchOne(rawDB, sql: "SELECT COUNT(*) FROM \(Schema.Integrations.tableName)") ?? -1
            XCTAssertEqual(count, 1)
        }
    }

    // MARK: - delete

    /// delete by provider — idempotent: отсутствующий row не throw'ит.
    func testDeleteIsIdempotent() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        XCTAssertNoThrow(try db.deleteIntegration(provider: .linear))

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try db.upsertIntegration(IntegrationRecord(
            provider: .linear, workspaceID: "ws", workspaceName: "Name",
            accessToken: "t", refreshToken: nil, expiresAt: nil,
            scope: "read", connectedAt: now, updatedAt: now
        ))
        XCTAssertNotNil(try db.readIntegration(provider: .linear))

        try db.deleteIntegration(provider: .linear)
        XCTAssertNil(try db.readIntegration(provider: .linear))

        // Повторный delete — no-op.
        XCTAssertNoThrow(try db.deleteIntegration(provider: .linear))
    }

    /// readIntegration на пустой таблице → nil (не throw, не error).
    func testReadReturnsNilWhenAbsent() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        XCTAssertNil(try db.readIntegration(provider: .linear))
    }

    // MARK: - Phase 4.4 Slack provider

    /// Slack round-trip: composite workspaceID `<team_id>:<user_id>` (no `slack:`
    /// prefix) + xoxp- user token + xoxe- refresh token + 12h expiry. Подтверждает
    /// что schema generic для provider'ов и не требует новой миграции (M005).
    func testUpsertSlackProviderRoundTrip() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let connected = Date(timeIntervalSince1970: 1_700_000_000)
        let expires = connected.addingTimeInterval(43200) // 12h
        let record = IntegrationRecord(
            provider: .slack,
            workspaceID: "T01ABC:U01DEF",
            workspaceName: "Acme",
            accessToken: "xoxp-test-access",
            refreshToken: "xoxe-1-test-refresh",
            expiresAt: expires,
            scope: "users:read,users.profile:read,search:read",
            connectedAt: connected,
            updatedAt: connected
        )
        try db.upsertIntegration(record)

        let loaded = try db.readIntegration(provider: .slack)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.provider, .slack)
        XCTAssertEqual(loaded?.workspaceID, "T01ABC:U01DEF")
        XCTAssertEqual(loaded?.workspaceName, "Acme")
        XCTAssertEqual(loaded?.accessToken, "xoxp-test-access")
        XCTAssertEqual(loaded?.refreshToken, "xoxe-1-test-refresh")
        XCTAssertEqual(loaded?.scope, "users:read,users.profile:read,search:read")
        XCTAssertEqual(loaded?.expiresAt?.timeIntervalSince1970 ?? 0, expires.timeIntervalSince1970, accuracy: 0.001)

        // Linear row отдельно — slack не пересекается по PK.
        XCTAssertNil(try db.readIntegration(provider: .linear))
    }
}
