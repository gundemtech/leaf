import XCTest

@testable import LeafCore

final class EgressEventTests: XCTestCase {
  func testInitFromRawEvent_usesEventKind() {
    let raw = RawEvent(
      timestamp: Date(timeIntervalSince1970: 100),
      signalType: .action,
      bundleID: "com.example.app",
      payload: ["event_kind": "gh_pr_opened", "title": "x"])
    let e = EgressEvent(raw: raw)
    XCTAssertEqual(e.kind, "gh_pr_opened")
    XCTAssertEqual(e.bundleID, "com.example.app")
    XCTAssertEqual(e.timestamp, Date(timeIntervalSince1970: 100))
    XCTAssertEqual(e.payload["title"], "x")
  }

  func testInitFromRawEvent_fallsBackToSignalTypeWhenNoEventKind() {
    let raw = RawEvent(signalType: .attention, bundleID: nil, payload: [:])
    XCTAssertEqual(EgressEvent(raw: raw).kind, "attention")
  }

  func testDescription_redactsValuesButKeepsKeyNames() {
    let e = EgressEvent(
      timestamp: Date(), kind: "k", bundleID: "b",
      payload: ["body": "SECRET-VALUE-12345", "additions": "50"])
    let d = e.description
    XCTAssertFalse(
      d.contains("SECRET-VALUE-12345"), "payload values MUST NOT appear in description (H3)")
    XCTAssertFalse(d.contains("50"), "payload values MUST NOT appear in description (H3)")
    XCTAssertTrue(d.contains("body"), "payload key names may appear")
    XCTAssertTrue(d.contains("additions"))
  }
}
