import XCTest

@testable import LeafCore

final class FactProjectionTests: XCTestCase {
  private func event(_ kind: String, _ payload: [String: String]) -> EgressEvent {
    EgressEvent(timestamp: Date(), kind: kind, bundleID: nil, payload: payload)
  }

  func testScalarFactsPassThroughUnderRawNames() {
    let out = FactProjection.project(
      event("issue_updated", ["issue_identifier": "LEA-100", "additions": "50"]),
      strictMode: false, authoredByViewer: false)
    XCTAssertEqual(out["issue_identifier"], "LEA-100")
    XCTAssertEqual(out["additions"], "50")
  }

  func testUnknownKeyDropped_failClosed() {
    let out = FactProjection.project(
      event("issue_updated", ["future_collector_field": "SENTINEL-UNKNOWN"]),
      strictMode: false, authoredByViewer: false)
    XCTAssertTrue(out.isEmpty, "unknown key must be dropped (fail-closed allow-list)")
  }

  func testBodyAndFreeTextKeysDropped() {
    let out = FactProjection.project(
      event(
        "linear_comment_authored",
        [
          "body": "SENTINEL-BODY", "channel_name": "leadership-layoffs",
          "gist_description": "SENTINEL-GIST", "title": "someone elses PR title",
        ]),
      strictMode: false, authoredByViewer: true)
    XCTAssertTrue(out.isEmpty, "bodies + free-text keys are not allow-listed → dropped")
  }

  func testSelfAuthoredCommit_goesWhenAuthoredAndNotStrict() {
    let out = FactProjection.project(
      event("gh_commit_pushed", ["title": "refactor auth + token race fix"]),
      strictMode: false, authoredByViewer: true)
    XCTAssertEqual(
      out["self_authored_commit"], "refactor auth + token race fix",
      "own commit subject goes by default under a distinct output key (§4.3)")
    XCTAssertNil(out["title"], "raw `title` key must never appear as an output key")
  }

  func testSelfAuthored_droppedWhenNotAuthoredByViewer() {
    let out = FactProjection.project(
      event("gh_pr_opened", ["title": "SOMEONE-ELSES-PR-TITLE"]),
      strictMode: false, authoredByViewer: false)
    XCTAssertTrue(out.isEmpty, "no authored-by-viewer signal → not mine → dropped (no mis-attribution)")
  }

  func testSelfAuthored_droppedUnderStrictMode() {
    let out = FactProjection.project(
      event("gh_commit_pushed", ["title": "my subject", "additions": "10"]),
      strictMode: true, authoredByViewer: true)
    XCTAssertNil(out["self_authored_commit"], "strict mode moves self-authored labels to escalation")
    XCTAssertEqual(out["additions"], "10", "scalar facts still go under strict mode")
  }

  func testSelfAuthoredLabelTruncatedToCap() {
    let long = String(repeating: "x", count: 500)
    let out = FactProjection.project(
      event("gh_commit_pushed", ["title": long]),
      strictMode: false, authoredByViewer: true)
    XCTAssertEqual(out["self_authored_commit"]?.count, EgressFactAllowlist.selfAuthoredCap)
  }

  // Allow-list invariants (CI guard substrate).
  func testScalarFactsAndBodyFieldsDisjoint() {
    XCTAssertTrue(
      EgressFactAllowlist.scalarFacts.isDisjoint(with: EgressFactAllowlist.bodyFields),
      "a key may not be both a dry fact and a body field")
  }

  func testBodyFieldsCoverSchemaBodyKeys() {
    let schemaBodyKeys: Set<String> = [
      Schema.EventPayloadKeys.body,
      Schema.EventPayloadKeys.bodyTruncated,
      Schema.EventPayloadKeys.attachmentsJson,
      Schema.EventPayloadKeys.commentBodiesJson,
      Schema.EventPayloadKeys.threadRepliesJson,
      Schema.EventPayloadKeys.messagesJson,
      Schema.EventPayloadKeys.notificationTitle,
    ]
    XCTAssertTrue(
      schemaBodyKeys.isSubset(of: EgressFactAllowlist.bodyFields),
      "every Schema body key must be in the bodyFields fence")
  }

  func testNoSelfAuthoredOutputKeyCollidesWithScalarOrBody() {
    XCTAssertTrue(EgressFactAllowlist.selfAuthoredOutputKeys.isDisjoint(with: EgressFactAllowlist.scalarFacts))
    XCTAssertTrue(EgressFactAllowlist.selfAuthoredOutputKeys.isDisjoint(with: EgressFactAllowlist.bodyFields))
  }
}
