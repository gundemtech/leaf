// AI-UI-2 — EscalationPreviewBuilder: per-event preview через ту же
// LLMPolicy.makeEscalation. Отсутствие id в карте = dropped (bucket-1 / нет body).

import XCTest

@testable import LeafCore

final class EscalationPreviewBuilderTests: XCTestCase {
  private func event(
    kind: String = "gh_pr_comment", bundleID: String? = nil, payload: [String: String]
  ) -> EgressEvent {
    EgressEvent(
      timestamp: Date(timeIntervalSince1970: 1), kind: kind, bundleID: bundleID, payload: payload)
  }

  // Body-bearing событие попадает в preview с capped-текстом — БИТ-В-БИТ с тем,
  // что построит makeEscalation на send-пути (включая "…" маркер усечения).
  func testBodyEvent_present_textCapped_exactSendParity() {
    let long = String(repeating: "x", count: LLMPolicy.escalationBodyCap + 500)
    let e = event(payload: ["body": long])
    let policy = LLMPolicy()
    let map = EscalationPreviewBuilder.preview(keyed: [(id: Int64(7), event: e)], policy: policy)
    let sent = policy.makeEscalation(selected: [e]).bodies.first
    XCTAssertNotNil(map[7])
    XCTAssertEqual(map[7], sent, "preview = exactly what the send path builds")
    XCTAssertTrue(map[7]?.text.hasSuffix("…") ?? false, "truncation is visible to the user")
  }

  // Без body → отсутствует (dropped).
  func testNoBodyEvent_absent() {
    let keyed = [(id: Int64(1), event: event(payload: ["title": "no body here"]))]
    XCTAssertNil(EscalationPreviewBuilder.preview(keyed: keyed, policy: LLMPolicy())[1])
  }

  // authoredByViewer переносится.
  func testAuthoredByViewer_carried() {
    let keyed = [
      (id: Int64(2), event: event(payload: ["body": "mine", "authored_by_viewer": "true"]))
    ]
    XCTAssertEqual(
      EscalationPreviewBuilder.preview(keyed: keyed, policy: LLMPolicy())[2]?.authoredByViewer, true)
  }

  // Sentinel (зеркало EscalationEgressLeakageTests): bucket-1 → отсутствует.
  func testBucketOneEvent_absent_neverPreviewed() {
    let policy = LLMPolicy(moat: LLMEgressMoat(neverToCloudBundleIDs: ["com.test.personal"]))
    let keyed = [
      (
        id: Int64(3),
        event: event(
          kind: "attention", bundleID: "com.test.personal",
          payload: ["body": "SENTINEL-PERSONAL-BODY"])
      )
    ]
    let map = EscalationPreviewBuilder.preview(keyed: keyed, policy: policy)
    XCTAssertNil(map[3])
  }
}
