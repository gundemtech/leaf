// AI-UI-2 — EscalationDraft: чистая модель escalation-модалки
// (выбор / фазы / single-flight / кап).

import XCTest

@testable import LeafCore

final class EscalationDraftTests: XCTestCase {
  private func entry(_ id: Int64) -> ActivityFeedEntry {
    ActivityFeedEntry(
      id: id, timestamp: Date(timeIntervalSince1970: TimeInterval(id)),
      provider: .github, eventKind: "gh_pr_comment", primaryText: "e\(id)")
  }

  private func body() -> EscalatedBody {
    EscalatedBody(kind: "gh_pr_comment", tsBucketMs: 0, authoredByViewer: true, text: "t")
  }

  private func draft(ids: [Int64], sendable: [Int64], preselected: Set<Int64> = [])
    -> EscalationDraft
  {
    EscalationDraft(
      candidates: ids.map(entry),
      preview: Dictionary(uniqueKeysWithValues: sendable.map { ($0, body()) }),
      preselected: preselected)
  }

  func testInit_preselectedIntersectedWithSendable() {
    let d = draft(ids: [1, 2, 3], sendable: [1, 2], preselected: [1, 2, 3])
    XCTAssertEqual(d.selected, [1, 2])
    XCTAssertEqual(d.sendableCount, 2)
  }

  func testToggle_droppedRejected() {
    var d = draft(ids: [1, 2], sendable: [1])
    XCTAssertFalse(d.toggle(2))
    XCTAssertTrue(d.toggle(1))
    XCTAssertTrue(d.isSelected(1))
    XCTAssertFalse(d.isSendable(2))
  }

  func testToggle_capRejected_deselectAllowed() {
    let ids = (1...Int64(EscalationDraft.selectionCap + 1)).map { $0 }
    var d = draft(
      ids: ids, sendable: ids, preselected: Set(ids.prefix(EscalationDraft.selectionCap)))
    XCTAssertEqual(d.selectedCount, EscalationDraft.selectionCap)
    XCTAssertFalse(d.toggle(ids.last!), "over cap rejected")
    XCTAssertTrue(d.toggle(ids.first!), "deselect always allowed")
    XCTAssertTrue(d.toggle(ids.last!), "after deselect there is room")
  }

  func testInit_preselectedCappedAtSelectionCap() {
    let ids = (1...Int64(EscalationDraft.selectionCap + 10)).map { $0 }
    let d = draft(ids: ids, sendable: ids, preselected: Set(ids))
    XCTAssertEqual(d.selectedCount, EscalationDraft.selectionCap)
  }

  func testSingleFlight_andPhaseTransitions() {
    var d = draft(ids: [1], sendable: [1], preselected: [1])
    XCTAssertTrue(d.beginSending())
    XCTAssertFalse(d.beginSending(), "single-flight")
    XCTAssertFalse(d.toggle(1), "no toggling while sending")
    d.resolve(answer: "ok")
    XCTAssertEqual(d.phase, .answered("ok"))
  }

  func testBeginSending_emptySelectionRejected() {
    var d = draft(ids: [1], sendable: [1])
    XCTAssertFalse(d.beginSending())
    XCTAssertEqual(d.phase, .composing)
  }

  func testFail_thenReset_retainsSelection() {
    var d = draft(ids: [1, 2], sendable: [1, 2], preselected: [1, 2])
    d.beginSending()
    let err = AIFailure(kind: .transient, message: "err")
    d.fail(err)
    XCTAssertEqual(d.phase, .failed(err))
    d.reset()
    XCTAssertEqual(d.phase, .composing)
    XCTAssertEqual(d.selected, [1, 2])
  }

  func testResolve_onlyFromSending() {
    var d = draft(ids: [1], sendable: [1], preselected: [1])
    d.resolve(answer: "nope")
    XCTAssertEqual(d.phase, .composing)
  }

  func testReset_onlyFromFailed() {
    var d = draft(ids: [1], sendable: [1], preselected: [1])
    d.beginSending()
    d.reset()
    XCTAssertEqual(d.phase, .sending)
  }
}
