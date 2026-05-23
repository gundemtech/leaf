import XCTest

@testable import LeafCore

/// Track-10 T7 — locks the bundled `CurrentTaskSession` value type contract
/// consumed by the Home YOU'RE ON block. Per-CTO F-CTO-A: no `Codable`
/// requirement — `TaskIdentity` is not Codable and we don't need JSON
/// round-trip for T7. `Equatable + Hashable + Sendable` cover SwiftUI diff,
/// Set dedup, and concurrency safety.
final class CurrentTaskSessionTests: XCTestCase {

    func testEquatable_distinctFocusedMinNotEqual() {
        let identity = TaskIdentity(linearID: "GUN-50")
        let a = CurrentTaskSession(
            taskIdentity: identity, sessionStartMs: 1_716_454_680_000,
            focusedMinSoFar: 92, openFiles: [])
        let b = CurrentTaskSession(
            taskIdentity: identity, sessionStartMs: 1_716_454_680_000,
            focusedMinSoFar: 93, openFiles: [])
        XCTAssertNotEqual(a, b)
    }

    func testHashable_setDedupsIdenticalValues() {
        let identity = TaskIdentity(linearID: "GUN-50")
        let a = CurrentTaskSession(
            taskIdentity: identity, sessionStartMs: 1, focusedMinSoFar: 2,
            openFiles: ["A.swift"])
        let dupSet: Set<CurrentTaskSession> = [a, a]
        XCTAssertEqual(dupSet.count, 1)
    }

    func testInit_preservesAllFields() {
        let task = TaskIdentity(
            linearID: "X-1", branch: "y", repo: "z",
            workspacePath: nil, linearWorkspaceSlug: "w")
        let session = CurrentTaskSession(
            taskIdentity: task, sessionStartMs: 42, focusedMinSoFar: 7,
            openFiles: ["foo.swift"])
        XCTAssertEqual(session.taskIdentity, task)
        XCTAssertEqual(session.sessionStartMs, 42)
        XCTAssertEqual(session.focusedMinSoFar, 7)
        XCTAssertEqual(session.openFiles, ["foo.swift"])
    }
}
