// Phase 5.1.B — public-side tests для team helpers (Org / TeamMember / TeamKey)
// поверх M006/M007/M008 schema substrate'а 5.1.A. Pure DB I/O round-trip + edge
// cases (partial-index queries via direct `removed_at_ms` / `deprecated_at_ms`
// SET через `db.writeSQL` raw-SQL escape — mark/deprecate helpers — задача 5.3).

import XCTest
import GRDB
@testable import LeafCore

final class DatabaseTeamTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-team-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Org

    /// Базовый round-trip: upsert → readOrg возвращает тот же row, все 4 поля
    /// match'ат, Date roundtrip без потерь (whole-second timestamps).
    func testUpsertOrgAndReadRoundTrip() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let org = Org(
            id: "org-aaaa",
            name: "Personal",
            createdAt: createdAt,
            createdByMemberID: "member-self"
        )
        try db.upsertOrg(org)

        let loaded = try db.readOrg()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, "org-aaaa")
        XCTAssertEqual(loaded?.name, "Personal")
        XCTAssertEqual(loaded?.createdAt, createdAt)
        XCTAssertEqual(loaded?.createdByMemberID, "member-self")
    }

    /// UPSERT по PK — re-write с тем же `id`, но новым `name`, обновляет fields.
    func testUpsertOrgUpdatesFieldsForSameID() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let initial = Org(
            id: "org-aaaa",
            name: "Personal",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdByMemberID: "member-self"
        )
        try db.upsertOrg(initial)

        let renamed = Org(
            id: "org-aaaa",
            name: "Acme Inc",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdByMemberID: "member-self"
        )
        try db.upsertOrg(renamed)

        let loaded = try db.readOrg()
        XCTAssertEqual(loaded?.name, "Acme Inc", "UPSERT должен был обновить name")
    }

    /// Fresh DB без upsert'а → readOrg() == nil.
    func testReadOrgReturnsNilWhenEmpty() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let loaded = try db.readOrg()
        XCTAssertNil(loaded)
    }
}
