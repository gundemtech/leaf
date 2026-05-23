import XCTest

@testable import LeafCore

final class ActiveWorkspaceResolverTests: XCTestCase {
  private func ws(_ id: String, createdAt: TimeInterval) -> Workspace {
    Workspace(
      id: id, name: id,
      createdAt: Date(timeIntervalSince1970: createdAt),
      createdByMemberID: "member-\(id)"
    )
  }

  func testKnownIDFound_ReturnsThatWorkspace_NoBackfill() {
    let list = [ws("a", createdAt: 100), ws("b", createdAt: 200)]
    let r = resolveActiveWorkspace(list, knownActiveID: "b")
    XCTAssertEqual(r.active?.id, "b")
    XCTAssertNil(r.backfilledID)
  }

  func testKnownIDNil_PicksOldestByCreatedAt_AndReportsBackfill() {
    let list = [ws("new", createdAt: 300), ws("old", createdAt: 100), ws("mid", createdAt: 200)]
    let r = resolveActiveWorkspace(list, knownActiveID: nil)
    XCTAssertEqual(r.active?.id, "old")
    XCTAssertEqual(r.backfilledID, "old")
  }

  func testKnownIDAbsent_ReturnsNilActive_NoBackfill() {
    let list = [ws("a", createdAt: 100)]
    let r = resolveActiveWorkspace(list, knownActiveID: "ghost")
    XCTAssertNil(r.active)
    XCTAssertNil(r.backfilledID)
  }

  func testEmptyList_ReturnsNilActive_NoBackfill() {
    let r = resolveActiveWorkspace([], knownActiveID: nil)
    XCTAssertNil(r.active)
    XCTAssertNil(r.backfilledID)
  }

  func testSingleWorkspace_KnownIDNil_BackfillsToIt() {
    let list = [ws("only", createdAt: 100)]
    let r = resolveActiveWorkspace(list, knownActiveID: nil)
    XCTAssertEqual(r.active?.id, "only")
    XCTAssertEqual(r.backfilledID, "only")
  }
}
