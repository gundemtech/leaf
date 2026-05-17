import XCTest

@testable import LeafCore

final class LinearCustomViewsDiffTests: XCTestCase {
    private func snap(_ id: String, _ name: String, _ updatedAtMs: Int64) -> LinearCustomViewSnapshot {
        .init(id: id, name: name, teamId: nil, updatedAtMs: updatedAtMs)
    }

    func testCreatedAndDeleted() {
        let d = LinearColdCollector.customViewsDiff(
            prior: [snap("a", "A", 1)],
            current: [snap("b", "B", 2)])
        XCTAssertEqual(d.created.map(\.id), ["b"])
        XCTAssertEqual(d.deleted.map(\.id), ["a"])
        XCTAssertTrue(d.updated.isEmpty)
    }

    func testUpdatedByNameChange() {
        let d = LinearColdCollector.customViewsDiff(
            prior: [snap("a", "Old", 1)],
            current: [snap("a", "New", 1)])
        XCTAssertEqual(d.updated.map(\.id), ["a"])
        XCTAssertTrue(d.created.isEmpty)
        XCTAssertTrue(d.deleted.isEmpty)
    }

    func testUpdatedByUpdatedAtChange() {
        let d = LinearColdCollector.customViewsDiff(
            prior: [snap("a", "Same", 1)],
            current: [snap("a", "Same", 2)])
        XCTAssertEqual(d.updated.map(\.id), ["a"])
    }

    func testNoChange() {
        let d = LinearColdCollector.customViewsDiff(
            prior: [snap("a", "Same", 1)],
            current: [snap("a", "Same", 1)])
        XCTAssertTrue(d.created.isEmpty)
        XCTAssertTrue(d.updated.isEmpty)
        XCTAssertTrue(d.deleted.isEmpty)
    }
}
