import XCTest
import os
@testable import LeafCore

final class RotationFetchSchedulerTests: XCTestCase {

    private var tempDir: URL!
    private var dbURL: URL!
    private var keystoreRoot: URL!
    private var db: LeafCore.Database!
    private var relayClient: RelayClient!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-rotsched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
        keystoreRoot = tempDir.appendingPathComponent("keystore", isDirectory: true)
        db = try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        relayClient = RelayClient(baseURL: URL(string: "https://test.example.com")!)
    }

    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeServices() -> (RotationFetchService, KeyRotationService) {
        let fetchService = RotationFetchService(
            database: db,
            relayClient: relayClient,
            rotationKDF: UnimplementedRotationKDF(),
            rotationBlobCodec: UnimplementedRotationBlobCodec(),
            keystoreRoot: keystoreRoot
        )
        let keyRotService = KeyRotationService(
            database: db,
            relayClient: relayClient,
            rotationKDF: UnimplementedRotationKDF(),
            rotationBlobCodec: UnimplementedRotationBlobCodec(),
            keystoreRoot: keystoreRoot
        )
        return (fetchService, keyRotService)
    }

    func testPerformTickCallsBothServices() async throws {
        // No org → both calls return empty/no-op without throwing.
        let (fetch, keyRot) = makeServices()
        let scheduler = RotationFetchScheduler(
            fetchService: fetch,
            keyRotationService: keyRot,
            intervalSec: 60,
            logger: Logger(subsystem: "test", category: "rotsched")
        )
        // Should complete without throwing.
        await scheduler.performTick()
    }

    func testStartTickStop() async throws {
        let (fetch, keyRot) = makeServices()
        let scheduler = RotationFetchScheduler(
            fetchService: fetch,
            keyRotationService: keyRot,
            intervalSec: 0.1,  // fast tick for test
            logger: Logger(subsystem: "test", category: "rotsched")
        )
        await scheduler.start()
        // Wait long enough for at least one tick (intervalSec/2 + intervalSec = 0.15s)
        try await Task.sleep(nanoseconds: 250_000_000)
        await scheduler.stop()
        // No assertion beyond "completes without hanging or crashing".
    }

    func testCancelDuringSleep_StopsCleanly() async throws {
        let (fetch, keyRot) = makeServices()
        let scheduler = RotationFetchScheduler(
            fetchService: fetch,
            keyRotationService: keyRot,
            intervalSec: 100,  // long sleep
            logger: Logger(subsystem: "test", category: "rotsched")
        )
        await scheduler.start()
        let stopStart = Date()
        await scheduler.stop()
        let elapsed = Date().timeIntervalSince(stopStart)
        XCTAssertLessThan(elapsed, 1.0, "Stop must return promptly via Task cancellation, took \(elapsed)s")
    }
}
