import XCTest

@testable import LeafCore

final class DebugDiagnosticsTests: XCTestCase {

    // MARK: - currentProcessCDHash / currentProcessBundlePath

    func testCurrentProcessCDHash_ReturnsHexOrNil() {
        // В тестовом раннере процесс подписан (xctest binary ad-hoc-signed
        // by Xcode); результат либо hex string, либо nil (если signing
        // identity не surface'нет CDHash). Главное — не crash.
        let result = DebugDiagnostics.currentProcessCDHash()
        if let hex = result {
            XCTAssertFalse(hex.isEmpty)
            XCTAssertTrue(
                hex.allSatisfy { $0.isHexDigit },
                "CDHash должен быть hex-only, got: \(hex)"
            )
        }
    }

    func testCurrentProcessBundlePath_NonEmpty() {
        let path = DebugDiagnostics.currentProcessBundlePath()
        XCTAssertFalse(path.isEmpty)
        XCTAssertTrue(path.hasPrefix("/"))
    }

    func testCdHashForPID_NonExistentReturnsNil() {
        // PID = -1 заведомо не существует.
        let result = DebugDiagnostics.cdHash(forPID: -1)
        XCTAssertNil(result)
    }

    // MARK: - File size helpers

    func testDbFileSize_MissingReturnsZero() {
        let nonexistent = URL(fileURLWithPath: "/tmp/leaf-diagnostics-test-\(UUID().uuidString).sqlite")
        XCTAssertEqual(DebugDiagnostics.dbFileSize(at: nonexistent), 0)
        XCTAssertEqual(DebugDiagnostics.dbWalSize(at: nonexistent), 0)
    }

    func testDbFileSize_ExistingReturnsSize() throws {
        let url = URL(fileURLWithPath: "/tmp/leaf-diagnostics-test-\(UUID().uuidString).sqlite")
        let payload = Data(repeating: 0x42, count: 128)
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(DebugDiagnostics.dbFileSize(at: url), 128)
    }

    // MARK: - DebugHeartbeat round-trip

    func testHeartbeat_WriteThenRead_RoundTrip() throws {
        let url = URL(fileURLWithPath: "/tmp/leaf-heartbeat-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let original = DebugHeartbeat(
            pid: 12345,
            axTrusted: true,
            cdHash: "abcdef0123",
            bundlePath: "/Applications/Leaf.app/Contents/MacOS/LeafAgent",
            tsMs: 1_700_000_000_000
        )
        try original.write(to: url)

        let restored = DebugHeartbeat.read(from: url)
        XCTAssertEqual(restored, original)
    }

    func testHeartbeat_MissingFileReturnsNil() {
        let url = URL(fileURLWithPath: "/tmp/leaf-heartbeat-missing-\(UUID().uuidString).json")
        XCTAssertNil(DebugHeartbeat.read(from: url))
    }

    func testHeartbeat_CorruptedFileReturnsNil() throws {
        let url = URL(fileURLWithPath: "/tmp/leaf-heartbeat-corrupt-\(UUID().uuidString).json")
        try Data("not valid json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(DebugHeartbeat.read(from: url))
    }

    func testHeartbeat_AgeSec_PositiveWhenInPast() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let oneMinuteAgo = DebugHeartbeat(
            pid: 1,
            axTrusted: true,
            cdHash: nil,
            bundlePath: "/x",
            tsMs: nowMs - 60_000
        )
        XCTAssertGreaterThan(oneMinuteAgo.ageSec, 58)
        XCTAssertLessThan(oneMinuteAgo.ageSec, 62)
    }

    func testHeartbeat_IsStale_WithThreshold() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let fresh = DebugHeartbeat(
            pid: 1, axTrusted: true, cdHash: nil, bundlePath: "/x", tsMs: nowMs - 10_000
        )
        let stale = DebugHeartbeat(
            pid: 1, axTrusted: true, cdHash: nil, bundlePath: "/x", tsMs: nowMs - 200_000
        )
        XCTAssertFalse(fresh.isStale())
        XCTAssertTrue(stale.isStale())
        XCTAssertTrue(fresh.isStale(staleThresholdSec: 5))
    }

    func testHeartbeat_DefaultURL_UnderApplicationSupportLeaf() {
        let url = DebugHeartbeat.defaultURL()
        XCTAssertEqual(url.lastPathComponent, "agent-heartbeat.json")
        XCTAssertTrue(url.path.contains("Application Support/Leaf"))
    }

    // MARK: - DB event stats (in-memory plaintext)

    func testEventStats_OnEmptyDatabase() throws {
        let url = makeTempDBURL()
        defer { cleanupDB(url) }
        let db = try Database.openForWrite(at: url, config: .weakDefaults, encryption: nil)

        XCTAssertEqual(try DebugDiagnostics.totalEvents(database: db), 0)
        XCTAssertNil(try DebugDiagnostics.lastEventAtMs(database: db))
        XCTAssertEqual(try DebugDiagnostics.eventsInLastMinute(database: db), 0)
    }

    func testEventStats_AfterWrite() throws {
        let url = makeTempDBURL()
        defer { cleanupDB(url) }
        let db = try Database.openForWrite(at: url, config: .weakDefaults, encryption: nil)

        let now = Date()
        let recent = RawEvent(
            timestamp: now.addingTimeInterval(-5),
            signalType: .attention,
            bundleID: "com.apple.Xcode",
            payload: [:]
        )
        let old = RawEvent(
            timestamp: now.addingTimeInterval(-600),
            signalType: .attention,
            bundleID: "com.apple.Xcode",
            payload: [:]
        )
        try db.write([recent, old])

        XCTAssertEqual(try DebugDiagnostics.totalEvents(database: db), 2)
        let expectedRecentMs = Int64(recent.timestamp.timeIntervalSince1970 * 1000)
        XCTAssertEqual(try DebugDiagnostics.lastEventAtMs(database: db), expectedRecentMs)
        XCTAssertEqual(try DebugDiagnostics.eventsInLastMinute(database: db, now: now), 1)
    }

    // MARK: - Helpers

    private func makeTempDBURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LeafDiagnosticsTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("events.sqlite", isDirectory: false)
    }

    private func cleanupDB(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
