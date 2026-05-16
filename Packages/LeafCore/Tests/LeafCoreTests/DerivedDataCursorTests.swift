// Phase Track-6 P2 — per-DerivedData-hash mtime cursor (provider_snapshots backed).
import Testing
import Foundation
@testable import LeafCore

@Suite("DerivedDataCursor / ProviderSnapshots-backed")
struct DerivedDataCursorTests {

    private func makeDB() throws -> LeafCore.Database {
        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ddwc-\(UUID().uuidString).sqlite")
        return try LeafCore.Database.openForWrite(
            at: dbURL,
            config: .weakDefaults,
            encryption: .deterministicTest
        )
    }

    @Test func roundTrip() async throws {
        let db = try makeDB()
        let cursor = ProviderSnapshotsDerivedDataCursor(database: db)
        await cursor.setLastSeenMtimeMs(1_700_000_000_000, forHash: "Leaf-abc")
        let v = await cursor.lastSeenMtimeMs(forHash: "Leaf-abc")
        #expect(v == 1_700_000_000_000)
    }

    @Test func multiHash() async throws {
        let db = try makeDB()
        let cursor = ProviderSnapshotsDerivedDataCursor(database: db)
        await cursor.setLastSeenMtimeMs(100, forHash: "a")
        await cursor.setLastSeenMtimeMs(200, forHash: "b")
        let hashes = await cursor.allKnownHashes()
        #expect(Set(hashes) == ["a", "b"])
        #expect(await cursor.lastSeenMtimeMs(forHash: "a") == 100)
        #expect(await cursor.lastSeenMtimeMs(forHash: "b") == 200)
    }

    @Test func unknownHash_returnsNil() async throws {
        let db = try makeDB()
        let cursor = ProviderSnapshotsDerivedDataCursor(database: db)
        #expect(await cursor.lastSeenMtimeMs(forHash: "ghost") == nil)
    }

    @Test func overwriteAdvancesMtime() async throws {
        let db = try makeDB()
        let cursor = ProviderSnapshotsDerivedDataCursor(database: db)
        await cursor.setLastSeenMtimeMs(100, forHash: "h")
        await cursor.setLastSeenMtimeMs(500, forHash: "h")
        #expect(await cursor.lastSeenMtimeMs(forHash: "h") == 500)
    }
}
