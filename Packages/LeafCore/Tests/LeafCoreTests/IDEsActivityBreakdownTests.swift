import XCTest
@testable import LeafCore

final class IDEsActivityBreakdownTests: XCTestCase {

    func test_empty_isAllZeros() {
        let empty = IDEsActivityBreakdown.empty
        XCTAssertEqual(empty.totalEventCount, 0)
        XCTAssertEqual(empty.vscodeFamilyEventCount, 0)
        XCTAssertEqual(empty.jetbrainsEventCount, 0)
        XCTAssertEqual(empty.fallbackTitleCount, 0)
        XCTAssertEqual(empty.workspaceCount, 0)
        XCTAssertTrue(empty.topWorkspaces.isEmpty)
        XCTAssertTrue(empty.topFiles.isEmpty)
        XCTAssertTrue(empty.dailyEvents.isEmpty)
    }

    func test_equatable_roundtrip() {
        let a = IDEsActivityBreakdown(
            totalEventCount: 20,
            vscodeFamilyEventCount: 12,
            jetbrainsEventCount: 5,
            fallbackTitleCount: 3,
            workspaceCount: 2,
            topWorkspaces: ["leaf", "leaf-docs"],
            topFiles: ["main.swift", "README.md"],
            dailyEvents: [1, 2, 3, 4, 5, 2, 3]
        )
        let aCopy = IDEsActivityBreakdown(
            totalEventCount: 20,
            vscodeFamilyEventCount: 12,
            jetbrainsEventCount: 5,
            fallbackTitleCount: 3,
            workspaceCount: 2,
            topWorkspaces: ["leaf", "leaf-docs"],
            topFiles: ["main.swift", "README.md"],
            dailyEvents: [1, 2, 3, 4, 5, 2, 3]
        )
        let b = IDEsActivityBreakdown(
            totalEventCount: 21,
            vscodeFamilyEventCount: 12,
            jetbrainsEventCount: 5,
            fallbackTitleCount: 3,
            workspaceCount: 2,
            topWorkspaces: ["leaf", "leaf-docs"],
            topFiles: ["main.swift", "README.md"],
            dailyEvents: [1, 2, 3, 4, 5, 2, 3]
        )
        XCTAssertEqual(a, aCopy)
        XCTAssertNotEqual(a, b)
    }

    func test_cardPayload_init_assignsFields() {
        let payload = IDEsCardPayload(
            fileEventCount: 30,
            workspaceCount: 4,
            vscodeFamilyEventCount: 18,
            jetbrainsEventCount: 9,
            fallbackTitleCount: 3,
            dailyEvents: [0, 0, 5, 10, 5, 5, 5]
        )
        XCTAssertEqual(payload.fileEventCount, 30)
        XCTAssertEqual(payload.workspaceCount, 4)
        XCTAssertEqual(payload.vscodeFamilyEventCount, 18)
        XCTAssertEqual(payload.jetbrainsEventCount, 9)
        XCTAssertEqual(payload.fallbackTitleCount, 3)
        XCTAssertEqual(payload.dailyEvents.count, 7)
    }

    func test_sendable_acrossTaskBoundary() async {
        let breakdown = IDEsActivityBreakdown.empty
        let echoed = await Task.detached { breakdown }.value
        XCTAssertEqual(echoed, breakdown)
    }
}
