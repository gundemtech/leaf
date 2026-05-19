//
//  PendingMarkDoneRetryServiceTests.swift
//  LeafCoreTests
//
//  Track 5 / S8 T6 — coverage for the APNs `dm.markDone` retry queue.
//
//  Behavioural invariants under test:
//   1. No-op when nothing pending (no spurious server calls).
//   2. Successful server PATCH clears the local flag.
//   3. Failed server PATCH leaves the flag set for the next tick.
//   4. Multiple pending rows are processed sequentially in one tick.
//

import XCTest
@testable import LeafCore

final class PendingMarkDoneRetryServiceTests: XCTestCase {

    func testTick_NoPendingRows_NoMarkDoneCalls() async throws {
        let mirror = MockPendingMarkDoneMirror()
        let client = MockMarkDoneClient(succeeds: true)
        let service = PendingMarkDoneRetryService(
            mirror: mirror,
            markDone: client.markDone
        )

        try await service.tick()

        let calls = await client.callCount
        XCTAssertEqual(calls, 0, "Empty pending set must not invoke server PATCH")
        let remaining = try await mirror.fetchPendingMarkDone()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testTick_SinglePendingRow_SuccessClearsFlag() async throws {
        let mirror = MockPendingMarkDoneMirror()
        await mirror.seedPending(messageID: "m1")
        let client = MockMarkDoneClient(succeeds: true)
        let service = PendingMarkDoneRetryService(
            mirror: mirror,
            markDone: client.markDone
        )

        try await service.tick()

        let calls = await client.callCount
        let callsByID = await client.callsByID
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(callsByID["m1"], 1)
        let remaining = try await mirror.fetchPendingMarkDone()
        XCTAssertTrue(remaining.isEmpty, "Successful server PATCH must clear pending_mark_done flag")
    }

    func testTick_SinglePendingRow_FailureRetainsFlag() async throws {
        let mirror = MockPendingMarkDoneMirror()
        await mirror.seedPending(messageID: "m1")
        let client = MockMarkDoneClient(succeeds: false)
        let service = PendingMarkDoneRetryService(
            mirror: mirror,
            markDone: client.markDone
        )

        try await service.tick()

        let calls = await client.callCount
        XCTAssertEqual(calls, 1, "Failure path still issues the PATCH attempt")
        let remaining = try await mirror.fetchPendingMarkDone()
        XCTAssertEqual(Set(remaining), ["m1"], "Failed PATCH must leave pending_mark_done = 1 for next tick")
    }

    func testTick_MultiplePendingRows_ProcessesAll() async throws {
        let mirror = MockPendingMarkDoneMirror()
        await mirror.seedPending(messageID: "m1")
        await mirror.seedPending(messageID: "m2")
        await mirror.seedPending(messageID: "m3")
        let client = MockMarkDoneClient(succeeds: true)
        let service = PendingMarkDoneRetryService(
            mirror: mirror,
            markDone: client.markDone
        )

        try await service.tick()

        let calls = await client.callCount
        let callsByID = await client.callsByID
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(Set(callsByID.keys), ["m1", "m2", "m3"])
        let remaining = try await mirror.fetchPendingMarkDone()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testTickIfDueDaily_FirstCallRuns_SecondCallSkipsWithinCooldown() async throws {
        let mirror = MockPendingMarkDoneMirror()
        await mirror.seedPending(messageID: "m1")
        // succeeds=false so the mirror flag stays set across multiple ticks,
        // making the call-count assertion the discriminator between
        // "ran the loop" vs "skipped due to cooldown".
        let client = MockMarkDoneClient(succeeds: false)
        let service = PendingMarkDoneRetryService(
            mirror: mirror,
            markDone: client.markDone
        )

        let firstCallTime = Date(timeIntervalSince1970: 1_000_000)
        try await service.tickIfDueDaily(now: firstCallTime)
        let callsAfterFirst = await client.callCount
        XCTAssertEqual(callsAfterFirst, 1, "First call runs the tick")

        // Second call 1 second later — should skip the tick.
        try await service.tickIfDueDaily(now: firstCallTime.addingTimeInterval(1))
        let callsAfterSecond = await client.callCount
        XCTAssertEqual(callsAfterSecond, 1, "Second call within cooldown skips")

        // Third call 25h later — should run again.
        try await service.tickIfDueDaily(now: firstCallTime.addingTimeInterval(25 * 3_600))
        let callsAfterThird = await client.callCount
        XCTAssertEqual(callsAfterThird, 2, "Call after cooldown elapses runs again")
    }
}

// MARK: - Test doubles

/// Actor-backed mirror double used to verify pending_mark_done flag
/// transitions across `PendingMarkDoneRetryService.tick()`. Conforms to
/// `PendingMarkDoneMirrorAccess` (defined in PendingMarkDoneRetryService.swift)
/// so the service treats the mock identically to the production
/// `MessagesMirrorStore`-backed shim.
actor MockPendingMarkDoneMirror: PendingMarkDoneMirrorAccess {

    private var pendingIDs: Set<String> = []

    func seedPending(messageID: String) {
        pendingIDs.insert(messageID)
    }

    func fetchPendingMarkDone() async throws -> [String] {
        // Sort for deterministic ordering across test asserts.
        Array(pendingIDs).sorted()
    }

    func setPendingMarkDone(messageID: String, pending: Bool) async throws {
        if pending {
            pendingIDs.insert(messageID)
        } else {
            pendingIDs.remove(messageID)
        }
    }
}

/// Actor-backed double for the server-PATCH closure injected into
/// `PendingMarkDoneRetryService`. `succeeds=false` throws a generic error per
/// call. Records call cardinality + per-ID call counts so tests can assert
/// each pending row was processed exactly once.
actor MockMarkDoneClient {

    let succeeds: Bool
    private(set) var callCount: Int = 0
    private(set) var callsByID: [String: Int] = [:]

    init(succeeds: Bool) {
        self.succeeds = succeeds
    }

    /// Sendable @Sendable closure factory that captures `self` weakly so it
    /// matches the `PendingMarkDoneRetryService.MarkDoneClient` signature.
    nonisolated var markDone: @Sendable (String) async throws -> Void {
        { [self] messageID in
            try await self.invoke(messageID)
        }
    }

    private func invoke(_ messageID: String) async throws {
        callCount += 1
        callsByID[messageID, default: 0] += 1
        if !succeeds {
            throw NSError(domain: "MockMarkDoneClient", code: 1, userInfo: nil)
        }
    }
}
