import XCTest

@testable import LeafCore

final class LLMPolicyTests: XCTestCase {
  private func event(_ kind: String, bundleID: String? = nil, _ payload: [String: String])
    -> EgressEvent
  {
    EgressEvent(timestamp: Date(timeIntervalSince1970: 1000), kind: kind, bundleID: bundleID, payload: payload)
  }

  func testProjectKeepsScalarFacts() {
    let policy = LLMPolicy()
    let out = policy.project(event("issue_updated", ["additions": "5"]))
    XCTAssertEqual(out?.payload["additions"], "5")
  }

  func testBucket1PersonalApp_droppedEntirely() {
    let policy = LLMPolicy(moat: LLMEgressMoat(neverToCloudBundleIDs: ["com.test.personal"]))
    XCTAssertNil(
      policy.project(event("attention", bundleID: "com.test.personal", ["additions": "5"])),
      "personal-app event must be dropped entirely (no body, no app, no time)")
  }

  func testSlackDM_droppedEntirely() {
    let policy = LLMPolicy()
    XCTAssertNil(
      policy.project(event("slack_message_authored_aggregate", ["channel_name": "DM", "reaction_count": "2"])),
      "Slack DM event must be dropped entirely (existence + timing is bucket-1)")
  }

  func testMakeContextOmitsBucket1AndEmptyProjections() {
    let policy = LLMPolicy(moat: LLMEgressMoat(neverToCloudBundleIDs: ["com.test.personal"]))
    let ctx = policy.makeContext(events: [
      event("issue_updated", ["additions": "5"]),  // kept
      event("attention", bundleID: "com.test.personal", ["additions": "9"]),  // bucket-1 → omitted
      event("linear_comment_authored", ["body": "secret"]),  // empty projection → omitted
    ])
    XCTAssertEqual(ctx.facts.count, 1)
    XCTAssertEqual(ctx.facts.first?.fields["additions"], "5")
  }

  func testMakeContextCarriesKindAndTimestamp() {
    let ctx = LLMPolicy().makeContext(events: [event("issue_updated", ["additions": "5"])])
    XCTAssertEqual(ctx.facts.first?.kind, "issue_updated")
    XCTAssertEqual(ctx.facts.first?.tsBucketMs, 1_000_000)
  }

  func testAuthoredByViewerSignalGatesSelfAuthored() {
    let policy = LLMPolicy()
    let mine = policy.makeContext(events: [
      event("gh_commit_pushed", ["title": "my work", "authored_by_viewer": "true"])
    ])
    XCTAssertEqual(mine.facts.first?.fields["self_authored_commit"], "my work")

    let notMine = policy.makeContext(events: [
      event("gh_commit_pushed", ["title": "someone elses"])
    ])
    XCTAssertTrue(notMine.facts.isEmpty, "absent authored-by-viewer → dropped")
  }
}
