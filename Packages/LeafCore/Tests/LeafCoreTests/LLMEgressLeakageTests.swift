// Track AI Coworker §8.1 acceptance gate — bodies / personal-app activity /
// free-text "facts" must never reach the cloud LLM on the default path.
// Mirrors RelayBodyLeakageTests discipline: inject a sentinel, run the policy,
// inspect PromptSafeContext.facts, assert the sentinel is ABSENT, WITH a
// positive gate so the negative assertion is never vacuous. The on-the-wire
// JSON no-leak assertion lives in the moat AnthropicSummarizerTests.
// Fixtures use Alice/Eve placeholders, never real names (leak-guard).

import XCTest

@testable import LeafCore

final class LLMEgressLeakageTests: XCTestCase {
  private func event(_ kind: String, bundleID: String? = nil, _ payload: [String: String])
    -> EgressEvent
  {
    EgressEvent(timestamp: Date(timeIntervalSince1970: 2000), kind: kind, bundleID: bundleID, payload: payload)
  }

  /// All kinds + output field keys + output field values, flattened to one
  /// string for substring assertions.
  private func rendered(_ ctx: PromptSafeContext) -> String {
    ctx.facts.map { fact in
      let fields = fact.fields.sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }.joined(separator: ";")
      return "\(fact.kind)|\(fields)"
    }.joined(separator: "\n")
  }

  private let policy = LLMPolicy()

  // 1.
  func testLinearBodyDoesNotReachContext() {
    let ctx = policy.makeContext(events: [
      event("issue_updated", ["body": "SENTINEL-LINEAR-BODY", "issue_identifier": "LEA-100"])
    ])
    let r = rendered(ctx)
    XCTAssertFalse(r.contains("SENTINEL-LINEAR-BODY"), "Linear body MUST NOT reach the LLM context")
    XCTAssertTrue(r.contains("LEA-100"), "positive gate: issue_identifier fact survives")
  }

  // 2.
  func testGitHubBodyDoesNotReachContext() {
    let ctx = policy.makeContext(events: [
      event("gh_pr_review_comment_authored", ["body": "SENTINEL-GH-BODY", "additions": "50"])
    ])
    let r = rendered(ctx)
    XCTAssertFalse(r.contains("SENTINEL-GH-BODY"))
    XCTAssertTrue(r.contains("additions=50"), "positive gate: additions fact survives")
  }

  // 3.
  func testSlackBodiesDoNotReachContext() {
    let ctx = policy.makeContext(events: [
      event(
        "slack_message_authored_aggregate",
        [
          "body": "SENTINEL-SLACK-BODY",
          "messages_json": "SENTINEL-MESSAGES-JSON",
          "thread_replies_json": "SENTINEL-THREAD-JSON",
          "reaction_count": "3",
        ])
    ])
    let r = rendered(ctx)
    XCTAssertFalse(r.contains("SENTINEL-SLACK-BODY"))
    XCTAssertFalse(r.contains("SENTINEL-MESSAGES-JSON"))
    XCTAssertFalse(r.contains("SENTINEL-THREAD-JSON"))
    XCTAssertTrue(r.contains("reaction_count=3"), "positive gate: reaction_count fact survives")
  }

  // 4.
  func testBucket1AppDroppedEntirely_neitherBodyNorAppTime() {
    let policy = LLMPolicy(moat: LLMEgressMoat(neverToCloudBundleIDs: ["com.test.personal"]))
    let ctx = policy.makeContext(events: [
      event("attention", bundleID: "com.test.personal", ["body": "SENTINEL-PERSONAL", "additions": "9"]),
      event("issue_updated", ["additions": "5"]),  // positive gate
    ])
    let r = rendered(ctx)
    XCTAssertFalse(r.contains("SENTINEL-PERSONAL"))
    XCTAssertFalse(r.contains("attention"), "bucket-1 event contributes no kind/app+time either")
    XCTAssertEqual(ctx.facts.count, 1)
    XCTAssertTrue(r.contains("additions=5"), "positive gate: a normal event survives")
  }

  // 5.
  func testSlackDMDroppedEntirely() {
    let ctx = policy.makeContext(events: [
      event("slack_message_authored_aggregate", ["channel_name": "DM", "reaction_count": "7"]),
      event("issue_updated", ["additions": "5"]),  // positive gate
    ])
    let r = rendered(ctx)
    XCTAssertFalse(r.contains("reaction_count=7"), "DM event (existence+timing) dropped entirely")
    XCTAssertEqual(ctx.facts.count, 1)
    XCTAssertTrue(r.contains("additions=5"))
  }

  // 6.
  func testSelfAuthoredCommitReachesContextUnderDistinctKey() {
    let ctx = policy.makeContext(events: [
      event("gh_commit_pushed", ["title": "MY-OWN-COMMIT-MARKER", "authored_by_viewer": "true"])
    ])
    let r = rendered(ctx)
    XCTAssertTrue(
      r.contains("self_authored_commit=MY-OWN-COMMIT-MARKER"),
      "§4.3: own commit subject goes by default under a distinct output key")
    XCTAssertFalse(r.contains("title="), "raw `title` key must never be an output key")
  }

  // 7.
  func testOthersTitleNotMisAttributed() {
    let ctx = policy.makeContext(events: [
      event("gh_pr_opened", ["title": "EVE-PR-TITLE"])  // no authored_by_viewer
    ])
    XCTAssertFalse(rendered(ctx).contains("EVE-PR-TITLE"), "others' title is not 'my' label → dropped")
  }

  // 8.
  func testStrictModeWithholdsSelfAuthored() {
    let strict = LLMPolicy(config: LLMPolicyConfig(strictMode: true))
    let ctx = strict.makeContext(events: [
      event("gh_commit_pushed", ["title": "MY-COMMIT", "authored_by_viewer": "true", "additions": "4"])
    ])
    let r = rendered(ctx)
    XCTAssertFalse(r.contains("MY-COMMIT"), "strict mode withholds self-authored labels")
    XCTAssertTrue(r.contains("additions=4"), "scalar facts still go under strict mode")
  }

  // 9.
  func testUnknownFutureKeyDroppedFailClosed() {
    let ctx = policy.makeContext(events: [
      event("issue_updated", ["future_collector_field": "SENTINEL-FUTURE", "additions": "1"])
    ])
    let r = rendered(ctx)
    XCTAssertFalse(r.contains("SENTINEL-FUTURE"), "a future un-classified key fails CLOSED (dropped)")
    XCTAssertTrue(r.contains("additions=1"))
  }

  // 10.
  func testFreeTextFactKeysDropped() {
    let ctx = policy.makeContext(events: [
      event(
        "gh_issue_comment_authored",
        [
          "channel_name": "leadership-comp",  // private channel name
          "gist_description": "SENTINEL-GIST",
          "title": "EVE-COMMENT-TITLE",
          "additions": "2",
        ])
    ])
    let r = rendered(ctx)
    XCTAssertFalse(r.contains("leadership-comp"))
    XCTAssertFalse(r.contains("SENTINEL-GIST"))
    XCTAssertFalse(r.contains("EVE-COMMENT-TITLE"))
    XCTAssertTrue(r.contains("additions=2"), "positive gate")
  }

  // 11.
  func testBodiesFenceUnconditional_noRawBodyKeyInOutput() {
    // For an others'-body event, no raw bodyFields key may appear as an output key.
    let ctx = policy.makeContext(events: [
      event("linear_comment_authored", ["body": "x", "note_title": "y", "additions": "1"])
    ])
    let outputKeys = Set(ctx.facts.flatMap { $0.fields.keys })
    XCTAssertTrue(
      outputKeys.isDisjoint(with: EgressFactAllowlist.bodyFields),
      "no raw body/free-text key may appear as a projection output key")
    // SSOT linkage.
    XCTAssertTrue(EgressFactAllowlist.scalarFacts.isDisjoint(with: EgressFactAllowlist.bodyFields))
  }

  // 12.
  func testPromptSafeContextSoleConstructorIsMakeContext() {
    // PromptSafeContext.init is `internal` (compile-time enforced); app/agent/mcp
    // targets cannot construct one. This test documents that makeContext is the
    // construction path and produces a usable value.
    let ctx = policy.makeContext(events: [event("issue_updated", ["additions": "1"])])
    XCTAssertEqual(ctx.facts.count, 1)
  }
}
