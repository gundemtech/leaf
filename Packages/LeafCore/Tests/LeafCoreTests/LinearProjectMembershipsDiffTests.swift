import XCTest

@testable import LeafCore

final class LinearProjectMembershipsDiffTests: XCTestCase {
    func testAddedRemoved() {
        let prior: [LinearProjectMembershipSnapshot] = [
            .init(projectId: "p1", projectName: "P1"),
            .init(projectId: "p2", projectName: "P2"),
        ]
        let current: [LinearProjectMembershipSnapshot] = [
            .init(projectId: "p2", projectName: "P2"),
            .init(projectId: "p3", projectName: "P3"),
        ]
        let d = LinearColdCollector.projectMembershipsDiff(prior: prior, current: current)
        XCTAssertEqual(Set(d.added.map(\.projectId)), Set(["p3"]))
        XCTAssertEqual(Set(d.removed.map(\.projectId)), Set(["p1"]))
    }
}
