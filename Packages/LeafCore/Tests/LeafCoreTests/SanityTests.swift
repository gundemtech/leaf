import XCTest

@testable import LeafCore

final class SanityTests: XCTestCase {
    func testSignalTypeRawValues() {
        XCTAssertEqual(SignalType.attention.rawValue, "attention")
        XCTAssertEqual(SignalType.allCases.count, 5)
    }

    func testGranularityOrdering() {
        XCTAssertTrue(Granularity.l1 < Granularity.l2)
        XCTAssertEqual(Granularity.allCases.count, 5)
        XCTAssertEqual(Granularity.allCases.last, .l5)
    }

    func testRawEventRoundTrip() throws {
        let event = RawEvent(
            signalType: .attention,
            bundleID: "com.apple.Xcode",
            payload: ["window": "project"]
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(RawEvent.self, from: data)
        XCTAssertEqual(decoded.signalType, .attention)
        XCTAssertEqual(decoded.bundleID, "com.apple.Xcode")
        XCTAssertEqual(decoded.payload["window"], "project")
    }

    func testPresenceSnapshotStatusCases() {
        XCTAssertEqual(PresenceSnapshot.Status.active.rawValue, "active")
        XCTAssertEqual(PresenceSnapshot.Status.activeGeneric.rawValue, "activeGeneric")
    }

    func testSchemaConstants() {
        XCTAssertEqual(Schema.Events.tableName, "events")
        XCTAssertEqual(Schema.Events.signalType, "signal_type")
    }

    func testDatabaseConfigWeakDefaults() {
        let config = DatabaseConfig.weakDefaults
        XCTAssertGreaterThan(config.busyTimeoutMs, 0)
        XCTAssertGreaterThan(config.walCheckpointIntervalSec, 0)
    }
}
