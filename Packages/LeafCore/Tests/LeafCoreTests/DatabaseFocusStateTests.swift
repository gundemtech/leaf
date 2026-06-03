import XCTest

@testable import LeafCore

/// Settings dead-toggle remediation (WS2) — latestFocusIsActive() reads the most
/// recent focus_mode_* event (written by the agent's FocusModeCollector) from the
/// shared DB so the app's willPresent can honor "Respect macOS Focus mode"
/// without a second TCC prompt. Fails open: no event → not in focus.
final class DatabaseFocusStateTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-ws2-focus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func focusEvent(_ kind: String, atMs: Int64) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: Double(atMs) / 1000.0),
            signalType: .context, bundleID: nil,
            payload: [
                "event_kind": kind,
                "state": kind == "focus_mode_enabled" ? "focused" : "not_focused",
            ])
    }

    func test_noFocusEvents_failsOpenToInactive() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        XCTAssertFalse(try db.latestFocusIsActive())
    }

    func test_latestEnabled_returnsActive() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try db.write([focusEvent("focus_mode_enabled", atMs: 1_000)])
        XCTAssertTrue(try db.latestFocusIsActive())
    }

    func test_disabledAfterEnabled_returnsInactive() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try db.write([focusEvent("focus_mode_enabled", atMs: 1_000)])
        try db.write([focusEvent("focus_mode_disabled", atMs: 2_000)])
        XCTAssertFalse(try db.latestFocusIsActive())
    }

    func test_ignoresLaterNonFocusEvents() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try db.write([focusEvent("focus_mode_enabled", atMs: 1_000)])
        let other = RawEvent(
            timestamp: Date(timeIntervalSince1970: 3.0), signalType: .attention,
            bundleID: "x", payload: ["event_kind": "active_app_changed"])
        try db.write([other])
        XCTAssertTrue(try db.latestFocusIsActive())
    }
}
