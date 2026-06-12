// Use-case rebuild Track B4 — menubar nudges section composition.

import XCTest
@testable import LeafCore

final class MenuBarNudgesPresentationTests: XCTestCase {

  private func nudge(_ id: String, sinceMs: Int64) -> NudgeItem {
    NudgeItem(id: id, kind: .stalledPR, title: id, detail: nil,
              sourceURL: nil, sinceMs: sinceMs)
  }

  func testEmpty_HidesSection() {
    XCTAssertNil(MenuBarNudgesPresentation.compose(nudges: []))
  }

  func testCapAndOrdering_OldestPainFirst() {
    let model = MenuBarNudgesPresentation.compose(nudges: [
      nudge("new", sinceMs: 3_000),
      nudge("oldest", sinceMs: 1_000),
      nudge("mid", sinceMs: 2_000),
      nudge("newest", sinceMs: 4_000),
    ])
    XCTAssertEqual(model?.rows.map(\.id), ["oldest", "mid", "new"], "cap 3, oldest first")
    XCTAssertEqual(model?.countLabel, "4 NUDGES", "count reflects ALL nudges, not the cap")
  }

  func testCopyStrings() {
    let model = MenuBarNudgesPresentation.compose(nudges: [nudge("one", sinceMs: 1)])
    XCTAssertEqual(model?.headerLabel, "you · last 24h")
    XCTAssertEqual(model?.countLabel, "1 NUDGE")
    XCTAssertEqual(model?.footer, "visible only to you · no manager dashboard")
  }
}
