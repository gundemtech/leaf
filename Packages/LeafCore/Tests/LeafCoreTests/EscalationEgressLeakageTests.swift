// Track AI Coworker §8.1 — ESCALATION-path acceptance gate (P3). The escalation
// path conditionally sends BODIES, but ONLY for explicitly-selected events that
// are bucket-1-cleared, capped, and provenance-tagged. These value-level
// sentinels prove makeEscalation's discipline; the default path stays body-free
// alongside it (regression guard). On-the-wire render/no-leak tests live in the
// moat. Fixtures use Alice/Eve/Alex placeholders, never real names (leak-guard).

import XCTest

@testable import LeafCore

final class EscalationEgressLeakageTests: XCTestCase {
  private func event(_ kind: String, bundleID: String? = nil, _ payload: [String: String])
    -> EgressEvent
  {
    EgressEvent(
      timestamp: Date(timeIntervalSince1970: 2000), kind: kind, bundleID: bundleID, payload: payload)
  }

  /// Flatten escalated bodies (kind|author|text) for substring assertions.
  private func rendered(_ b: EscalatedBodies) -> String {
    b.bodies.map { "\($0.kind)|author=\($0.authoredByViewer)|\($0.text)" }.joined(separator: "\n")
  }

  private let policy = LLMPolicy()

  // 1. bucket-1 personal-app selected body DROPPED (selection does NOT override bucket-1).
  func testBucket1PersonalAppBodyDropped() {
    let policy = LLMPolicy(moat: LLMEgressMoat(neverToCloudBundleIDs: ["com.test.personal"]))
    let out = policy.makeEscalation(selected: [
      event("attention", bundleID: "com.test.personal", ["body": "SENTINEL-PERSONAL-BODY"]),
      event("gh_pr_review_comment_authored", ["body": "SENTINEL-OK"]),
    ])
    let r = rendered(out)
    XCTAssertFalse(r.contains("SENTINEL-PERSONAL-BODY"), "personal-app body MUST NOT escalate even when named")
    XCTAssertEqual(out.bodies.count, 1)
    XCTAssertTrue(r.contains("SENTINEL-OK"), "positive gate: a non-bucket-1 body survives")
  }

  // 2. bucket-1 Slack DM (channel_name == "DM") body DROPPED.
  func testBucket1SlackDMByNameDropped() {
    let out = policy.makeEscalation(selected: [
      event("slack_message_authored_aggregate", ["channel_name": "DM", "body": "SENTINEL-DM-BODY"])
    ])
    XCTAssertTrue(out.bodies.isEmpty)
    XCTAssertFalse(rendered(out).contains("SENTINEL-DM-BODY"))
  }

  // 3. bucket-1 Slack DM (channel_id "D"-prefix) body DROPPED.
  func testBucket1SlackDMByChannelIDPrefixDropped() {
    let out = policy.makeEscalation(selected: [
      event("slack_thread_reply_aggregate", ["channel_id": "D0123ABC", "body": "SENTINEL-DMID-BODY"])
    ])
    XCTAssertTrue(out.bodies.isEmpty)
    XCTAssertFalse(rendered(out).contains("SENTINEL-DMID-BODY"))
  }

  // 4. Only the selected set escalates; a body-free context from a DIFFERENT set
  //    carries no body.
  func testOnlySelectedEscalates_contextStaysBodyFree() {
    let selected = [event("gh_issue_comment_authored", ["body": "SENTINEL-X"])]
    let other = [event("issue_updated", ["body": "SENTINEL-Y", "issue_identifier": "LEA-9"])]
    let bodies = policy.makeEscalation(selected: selected)
    let ctx = policy.makeContext(events: other)
    XCTAssertTrue(rendered(bodies).contains("SENTINEL-X"))
    XCTAssertFalse(rendered(bodies).contains("SENTINEL-Y"), "non-selected body never enters escalation")
    let ctxFlat = ctx.facts.map { "\($0.kind)|\($0.fields)" }.joined()
    XCTAssertFalse(ctxFlat.contains("SENTINEL-Y"), "context path stays body-free")
  }

  // 5. Cap applied — VALUE-level (tail sentinel cut, not just length bounded).
  func testBodyCappedAndTailTruncated() {
    let cap = LLMPolicy.escalationBodyCap
    let long = String(repeating: "A", count: cap + 500) + "SENTINEL-TAIL"
    let out = policy.makeEscalation(selected: [event("gh_pr_opened", ["body": long])])
    let text = out.bodies.first?.text ?? ""
    XCTAssertLessThanOrEqual(text.count, cap + 1, "capped to cap (+1 ellipsis)")
    XCTAssertFalse(text.contains("SENTINEL-TAIL"), "the tail past the cap was truncated away")
  }

  // 6. Provenance — self.
  func testProvenanceSelf() {
    let out = policy.makeEscalation(selected: [
      event("gh_pr_opened", ["body": "mine", "authored_by_viewer": "true"])
    ])
    XCTAssertEqual(out.bodies.first?.authoredByViewer, true)
  }

  // 7. Provenance — other (absent flag → false, no inference).
  func testProvenanceOtherWhenFlagAbsent() {
    let out = policy.makeEscalation(selected: [
      event("gh_pr_review_comment_authored", ["body": "theirs"])
    ])
    XCTAssertEqual(out.bodies.first?.authoredByViewer, false)
  }

  // 8. Empty / missing body contributes nothing (no bare kind+time leak).
  func testEmptyOrMissingBodyOmitted() {
    let out = policy.makeEscalation(selected: [
      event("gh_pr_opened", ["additions": "3"]),  // no body
      event("gh_issue_comment_authored", ["body": ""]),  // empty body
    ])
    XCTAssertTrue(out.bodies.isEmpty)
  }

  // 9. Default context stays body-free even when escalation is also built from
  //    the same body-bearing events — the P1/P2 regression guard.
  func testDefaultContextBodyFreeAlongsideEscalation() {
    let evs = [event("gh_pr_review_comment_authored", ["body": "SENTINEL-CTX-BODY", "additions": "7"])]
    _ = policy.makeEscalation(selected: evs)
    let ctx = policy.makeContext(events: evs)
    let ctxFlat = ctx.facts.map { "\($0.kind)|\($0.fields)" }.joined()
    XCTAssertFalse(ctxFlat.contains("SENTINEL-CTX-BODY"), "default path never carries a body")
  }

  // 10. makeEscalation is the sole producer of a usable EscalatedBodies (init is
  //     internal — compile-time topology; here we assert it produces values).
  func testMakeEscalationProducesUsableValue() {
    let out = policy.makeEscalation(selected: [event("gh_pr_opened", ["body": "hello"])])
    XCTAssertEqual(out.bodies.count, 1)
    XCTAssertEqual(out.bodies.first?.text, "hello")
    XCTAssertEqual(out.bodies.first?.kind, "gh_pr_opened")
  }
}
