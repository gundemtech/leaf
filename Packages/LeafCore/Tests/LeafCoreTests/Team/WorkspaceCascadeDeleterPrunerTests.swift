// Track 5 / S8 / T8 — WorkspaceCascadeDeleter.pruneExpiredLeftWorkspaces
// edge cases. Five tests cover the 30d retention boundary on each axis
// (leftAt / deletedAt) plus the active-workspace negative + idempotency.

import XCTest
import GRDB
@testable import LeafCore

final class WorkspaceCascadeDeleterPrunerTests: XCTestCase {
    private var tempDir: URL!
    private var keystoreRoot: URL!
    private var dbURL: URL!
    private var db: LeafCore.Database!

    /// Reference "now" anchor — a high round timestamp so subtractions don't
    /// underflow. Sub-tests pick offsets in days from this anchor.
    private let nowMs: Int64 = 1_800_000_000_000
    private var nowDate: Date { Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0) }

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-pruner-\(UUID().uuidString)")
        keystoreRoot = tempDir.appendingPathComponent("keystore", isDirectory: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
        db = try! LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: nil)
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeService(now: Date) -> WorkspaceService {
        WorkspaceService(
            database: db,
            keystoreRoot: keystoreRoot,
            now: { now },
            randomBytes: { count in Data(repeating: 0x42, count: count) },
            randomUUID: { UUID().uuidString.lowercased() }
        )
    }

    private func makeDeleter(now: Date) -> WorkspaceCascadeDeleter {
        WorkspaceCascadeDeleter(
            database: db,
            keystoreRoot: keystoreRoot,
            now: { now }
        )
    }

    /// Edge case 1 — workspace left 31 days ago: WIPED.
    func testPrune_WorkspacePastThreshold_Wiped() async throws {
        let svc = makeService(now: nowDate)
        let ws = try svc.createWorkspace(displayName: "Acme")
        // Left 31 days ago — past the 30d retention.
        let leftAt = Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0 - 31 * 86_400)
        try svc.markLeft(workspaceID: ws.id, at: leftAt)

        let deleter = makeDeleter(now: nowDate)
        let wiped = try await deleter.pruneExpiredLeftWorkspaces()
        XCTAssertEqual(wiped, [ws.id], "31-day-left workspace must be pruned")
        XCTAssertNil(try db.readWorkspace(id: ws.id),
                     "wiped workspace row must be gone after prune")
    }

    /// Edge case 2 — workspace left 15 days ago: PRESERVED (within window).
    func testPrune_WorkspaceWithin30d_NotWiped() async throws {
        let svc = makeService(now: nowDate)
        let ws = try svc.createWorkspace(displayName: "Beta")
        let leftAt = Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0 - 15 * 86_400)
        try svc.markLeft(workspaceID: ws.id, at: leftAt)

        let deleter = makeDeleter(now: nowDate)
        let wiped = try await deleter.pruneExpiredLeftWorkspaces()
        XCTAssertTrue(wiped.isEmpty, "15-day-left workspace must NOT be pruned (within 30d)")
        XCTAssertNotNil(try db.readWorkspace(id: ws.id),
                        "within-window workspace row must remain")
    }

    /// Edge case 3 — active workspace with no leftAt and no deletedAt: PRESERVED.
    func testPrune_NoLeftAtAndNoDeletedAt_NotWiped() async throws {
        let svc = makeService(now: nowDate)
        let ws = try svc.createWorkspace(displayName: "Gamma")

        let deleter = makeDeleter(now: nowDate)
        let wiped = try await deleter.pruneExpiredLeftWorkspaces()
        XCTAssertTrue(wiped.isEmpty, "active workspace must never be pruned")
        XCTAssertNotNil(try db.readWorkspace(id: ws.id))
    }

    /// Edge case 4 — admin-deleted (deletedAtMs) 31 days ago: WIPED.
    func testPrune_DeletedAtPastThreshold_Wiped() async throws {
        let svc = makeService(now: nowDate)
        let ws = try svc.createWorkspace(displayName: "Delta")
        let deleteAt = Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0 - 31 * 86_400)
        try svc.softDelete(workspaceID: ws.id, at: deleteAt)

        let deleter = makeDeleter(now: nowDate)
        let wiped = try await deleter.pruneExpiredLeftWorkspaces()
        XCTAssertEqual(wiped, [ws.id],
                       "31-day-deleted workspace must be pruned (deletedAt axis)")
        XCTAssertNil(try db.readWorkspace(id: ws.id))
    }

    /// Edge case 5 — idempotency: calling twice returns [] on the second call
    /// because the row was wiped by the first.
    func testPrune_Idempotent_WipedRowReturnsZeroOnNext() async throws {
        let svc = makeService(now: nowDate)
        let ws = try svc.createWorkspace(displayName: "Epsilon")
        let leftAt = Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0 - 45 * 86_400)
        try svc.markLeft(workspaceID: ws.id, at: leftAt)

        let deleter = makeDeleter(now: nowDate)
        let first = try await deleter.pruneExpiredLeftWorkspaces()
        XCTAssertEqual(first, [ws.id])

        let second = try await deleter.pruneExpiredLeftWorkspaces()
        XCTAssertTrue(second.isEmpty,
                      "second prune must return [] — already-wiped row no longer matches SELECT")
    }

    /// Bonus: pruner wipes the right workspace among many. Two left expired,
    /// one left fresh, one active.
    func testPrune_PartialBatch_WipesOnlyExpired() async throws {
        let svc = makeService(now: nowDate)
        let expired1 = try svc.createWorkspace(displayName: "Expired1")
        let expired2 = try svc.createWorkspace(displayName: "Expired2")
        let recent = try svc.createWorkspace(displayName: "Recent")
        let active = try svc.createWorkspace(displayName: "Active")

        try svc.markLeft(
            workspaceID: expired1.id,
            at: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0 - 31 * 86_400)
        )
        try svc.softDelete(
            workspaceID: expired2.id,
            at: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0 - 60 * 86_400)
        )
        try svc.markLeft(
            workspaceID: recent.id,
            at: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0 - 5 * 86_400)
        )

        let deleter = makeDeleter(now: nowDate)
        let wiped = try await deleter.pruneExpiredLeftWorkspaces()
        XCTAssertEqual(Set(wiped), Set([expired1.id, expired2.id]))

        XCTAssertNil(try db.readWorkspace(id: expired1.id))
        XCTAssertNil(try db.readWorkspace(id: expired2.id))
        XCTAssertNotNil(try db.readWorkspace(id: recent.id))
        XCTAssertNotNil(try db.readWorkspace(id: active.id))
    }

    // MARK: - S8 review B-Imp-3 — tickIfDueDaily cooldown gate

    /// First call to `tickIfDueDaily` runs the SELECT (lastPrunedAt = nil).
    /// Immediate second call (no time advance) hits cooldown and returns [].
    func testTickIfDueDaily_SecondCallWithinCooldown_NoOp() async throws {
        let svc = makeService(now: nowDate)
        let ws = try svc.createWorkspace(displayName: "Acme")
        try svc.markLeft(
            workspaceID: ws.id,
            at: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0 - 31 * 86_400)
        )

        let deleter = makeDeleter(now: nowDate)
        let first = try await deleter.tickIfDueDaily()
        XCTAssertEqual(first, [ws.id], "first call wipes the expired workspace")
        XCTAssertNil(try db.readWorkspace(id: ws.id))

        // Re-create another expired row; immediate second call hits cooldown.
        let ws2 = try svc.createWorkspace(displayName: "Beta")
        try svc.markLeft(
            workspaceID: ws2.id,
            at: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0 - 31 * 86_400)
        )
        let second = try await deleter.tickIfDueDaily()
        XCTAssertEqual(second, [], "cooldown blocks the second call within 24h")
        XCTAssertNotNil(try db.readWorkspace(id: ws2.id),
                        "ws2 must NOT be wiped while cooldown is in effect")
    }

    /// After 24h+1s elapses (currentTime arg advances), cooldown lifts and the
    /// next `tickIfDueDaily` runs the SELECT again.
    func testTickIfDueDaily_AfterCooldown_RunsAgain() async throws {
        let svc = makeService(now: nowDate)
        let deleter = makeDeleter(now: nowDate)
        // Prime cooldown via initial empty-prune tick.
        let initial = try await deleter.tickIfDueDaily()
        XCTAssertEqual(initial, [])

        // Seed an expired workspace + advance clock past cooldown boundary.
        let ws = try svc.createWorkspace(displayName: "Gamma")
        try svc.markLeft(
            workspaceID: ws.id,
            at: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0 - 31 * 86_400)
        )
        let pastCooldown = nowDate.addingTimeInterval(WorkspaceCascadeDeleter.dailyCooldownSeconds + 1)
        let next = try await deleter.tickIfDueDaily(currentTime: pastCooldown)
        XCTAssertEqual(next, [ws.id],
                        "expired workspace must wipe on next tick after cooldown lifts")
        XCTAssertNil(try db.readWorkspace(id: ws.id))
    }
}
