import XCTest

@testable import LeafCore

final class LinearSubscribedIssuesDiffTests: XCTestCase {
    func testAddedAndRemoved() {
        let result = LinearWarmCollector.subscribedIssuesDiff(prior: ["a", "b", "c"], current: ["b", "c", "d", "e"])
        XCTAssertEqual(Set(result.added), Set(["d", "e"]))
        XCTAssertEqual(Set(result.removed), Set(["a"]))
    }
    func testNoChange() {
        let r = LinearWarmCollector.subscribedIssuesDiff(prior: ["x"], current: ["x"])
        XCTAssertTrue(r.added.isEmpty)
        XCTAssertTrue(r.removed.isEmpty)
    }
    func testAllAdded() {
        let r = LinearWarmCollector.subscribedIssuesDiff(prior: [], current: ["a", "b"])
        XCTAssertEqual(Set(r.added), Set(["a", "b"]))
        XCTAssertTrue(r.removed.isEmpty)
    }
    func testAllRemoved() {
        let r = LinearWarmCollector.subscribedIssuesDiff(prior: ["a", "b"], current: [])
        XCTAssertTrue(r.added.isEmpty)
        XCTAssertEqual(Set(r.removed), Set(["a", "b"]))
    }
}
