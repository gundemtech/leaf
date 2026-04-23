import XCTest
@testable import LeafControlCore

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

    func testUnimplementedInsightsThrows() {
        struct FakeDB: DatabaseAccess {
            static func openForWrite(at url: URL, key: Data) throws -> FakeDB { FakeDB() }
            static func openForRead(at url: URL, key: Data) throws -> FakeDB { FakeDB() }
            func write(_ event: RawEvent) throws {}
            func events(in range: DateInterval, bundleID: String?) throws -> [RawEvent] { [] }
            func checkpointWAL() throws {}
        }
        let insights = UnimplementedInsights<FakeDB>()
        let period = DateInterval(start: .distantPast, end: .distantFuture)
        XCTAssertThrowsError(try insights.timeInApp(period: period))
    }

    func testPresenceSnapshotStatusCases() {
        XCTAssertEqual(PresenceSnapshot.Status.active.rawValue, "active")
        XCTAssertEqual(PresenceSnapshot.Status.activeGeneric.rawValue, "activeGeneric")
    }
}
