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

  // 5b. DM detected via raw IM channel id ("D"-prefix), no channel_name present.
  func testSlackDMByChannelIDDroppedEntirely() {
    let ctx = policy.makeContext(events: [
      event("slack_reaction_added", ["channel_id": "D0123456789", "reaction_count": "4"]),
      event("issue_updated", ["additions": "5"]),  // positive gate
    ])
    let r = rendered(ctx)
    XCTAssertFalse(r.contains("reaction_count=4"), "IM-id (D-prefix) DM event dropped even without channel_name")
    XCTAssertTrue(r.contains("additions=5"))
  }

  // 5c. CHARACTERIZATION of the documented P1 residual (CTO-2 / §8.5): a group-DM
  // (MPIM, "G" id) event arriving WITHOUT a "DM" channel_name cannot be
  // distinguished from a private work channel by prefix, so its scalar facts
  // currently project. This test pins that behavior so the P1 capture-side
  // is_dm fix is visible as a change here, not a silent one.
  func testKnownGap_groupDMWithoutNameStillProjectsScalarFacts() {
    let ctx = policy.makeContext(events: [
      event("slack_reaction_added", ["channel_id": "G0123456789", "reaction_count": "4"])
    ])
    XCTAssertTrue(
      rendered(ctx).contains("reaction_count=4"),
      "documented residual: MPIM-without-name leaks scalar count+timing until the P1 is_dm flag lands")
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

  // MARK: - P1 synthetic-fact shapes (CR-3 — the new gatherer path must obey §8.1 too)

  // 13. Synthetic recap metrics: identity-free scalars survive; planted file path
  //     + app-name free text are dropped (CR-2 / N-1).
  func testRecapMetricsScalarsSurvive_noPathOrAppName() {
    let ctx = policy.makeContext(events: [
      event(
        "recap_metrics",
        [
          "focus_session_count": "12",
          "ai_ratio_pct": "30",
          "files_touched_count": "47",
          "files_touched": "/Users/alice/secret-acquisition.md",  // path — must NOT ship
          "app_time_top_app_name": "SENTINEL-APPNAME",  // free text — must NOT ship
        ])
    ])
    let r = rendered(ctx)
    XCTAssertFalse(r.contains("secret-acquisition"), "file paths never reach the LLM (CR-2)")
    XCTAssertFalse(r.contains("SENTINEL-APPNAME"), "app-name free text never reaches the LLM")
    XCTAssertTrue(r.contains("focus_session_count=12"))
    XCTAssertTrue(r.contains("ai_ratio_pct=30"))
    XCTAssertTrue(r.contains("files_touched_count=47"), "positive gate: the count (not the paths) survives")
  }

  // 14. blocker_fact structured-only — excerpt dropped, refs/kinds survive.
  func testBlockerFactStructuredOnly_excerptDropped() {
    let ctx = policy.makeContext(events: [
      event(
        "blocker_fact",
        [
          "target_kind": "github_pr", "target_ref": "PR-42", "blocker_kind": "awaiting_review",
          "started_at_ms": "1700000000000",
          "blocker_excerpt": "SENTINEL-BLOCKER-EXCERPT",
        ])
    ])
    let r = rendered(ctx)
    XCTAssertFalse(r.contains("SENTINEL-BLOCKER-EXCERPT"), "detector excerpt is escalation-only (P3)")
    XCTAssertTrue(r.contains("target_ref=PR-42"))
    XCTAssertTrue(r.contains("blocker_kind=awaiting_review"))
  }

  // 15. open_question_fact structured-only — excerpt + alternatives dropped, refs survive.
  func testOpenQuestionFactStructuredOnly_excerptDropped() {
    let ctx = policy.makeContext(events: [
      event(
        "open_question_fact",
        [
          "linear_issue_ref": "LEA-88", "opened_at_ms": "1700000000000",
          "question_excerpt": "SENTINEL-Q-EXCERPT",
          "alternatives_json": "SENTINEL-ALTS",
        ])
    ])
    let r = rendered(ctx)
    XCTAssertFalse(r.contains("SENTINEL-Q-EXCERPT"))
    XCTAssertFalse(r.contains("SENTINEL-ALTS"))
    XCTAssertTrue(r.contains("linear_issue_ref=LEA-88"))
  }

  // 16. where_stopped_fact — wip booleans only, excerpt dropped.
  func testWhereStoppedFactWipOnly_excerptDropped() {
    let ctx = policy.makeContext(events: [
      event(
        "where_stopped_fact",
        [
          "wip_commit": "true", "wip_ci_failing": "false", "wip_mid_edit": "true",
          "generated_at_ms": "1700000000000",
          "excerpt": "SENTINEL-WHERE-EXCERPT",
        ])
    ])
    let r = rendered(ctx)
    XCTAssertFalse(r.contains("SENTINEL-WHERE-EXCERPT"))
    XCTAssertTrue(r.contains("wip_commit=true"))
  }

  // 17. Self-authored PR title (a P1 self-authored kind) under a distinct output key.
  func testSelfAuthoredPRTitleUnderDistinctKey() {
    let ctx = policy.makeContext(events: [
      event("gh_pr_opened", ["title": "ALICE-PR-REFACTOR-AUTH", "authored_by_viewer": "true", "additions": "9"])
    ])
    let r = rendered(ctx)
    XCTAssertTrue(r.contains("self_authored_title=ALICE-PR-REFACTOR-AUTH"))
    // Assert on the actual output KEY set — the raw `title` key must not appear
    // (a substring check would false-match inside `self_authored_title`).
    let outputKeys = Set(ctx.facts.flatMap { $0.fields.keys })
    XCTAssertFalse(outputKeys.contains("title"), "raw `title` key never an output key")
    XCTAssertTrue(outputKeys.contains("self_authored_title"))
  }

  // 18. window_title (L3 content) is fenced — never an output key.
  func testWindowTitleFenced() {
    let ctx = policy.makeContext(events: [
      event("attention", ["window_title": "SENTINEL-WINDOW-TITLE", "additions": "1"])
    ])
    XCTAssertFalse(rendered(ctx).contains("SENTINEL-WINDOW-TITLE"), "window_title is never projected")
  }

  // 19. Disjointness invariants for the P1 derived set.
  func testDerivedScalarFactsDisjointInvariants() {
    XCTAssertTrue(
      EgressFactAllowlist.derivedScalarFacts.isDisjoint(with: EgressFactAllowlist.bodyFields),
      "a derived scalar key must never also be a fenced body key")
    XCTAssertTrue(
      EgressFactAllowlist.derivedScalarFacts.isDisjoint(with: EgressFactAllowlist.scalarFacts),
      "no drift/dup between the raw and derived scalar sets")
  }

  // MARK: - P2 cluster 3a — linked_linear_id rides self-authored events; repo fenced

  // 20. The denormalized PR↔task link (linked_linear_id) ships on a self-authored
  //     PR alongside number + self_authored_title; the `repo` slug ("owner/repo")
  //     and the raw `title` never do. This is cluster 3a — zero producer code,
  //     it rides the existing self-authored gh_* flow.
  func testLinkedLinearIDShipsOnSelfAuthoredPR_repoAndTitleFenced() {
    let ctx = policy.makeContext(events: [
      event(
        "gh_pr_opened",
        [
          "authored_by_viewer": "true",
          "number": "42",
          "title": "ALICE-PR-REFACTOR-AUTH",
          "linked_linear_id": "LEAF-88",
          "repo": "acme/secret-repo",
        ])
    ])
    let r = rendered(ctx)
    XCTAssertTrue(r.contains("linked_linear_id=LEAF-88"), "denormalized PR↔task link ships (cluster 3a)")
    XCTAssertTrue(r.contains("number=42"), "PR number (the from-side ref) ships")
    XCTAssertTrue(r.contains("self_authored_title=ALICE-PR-REFACTOR-AUTH"), "own title under distinct key")
    XCTAssertFalse(r.contains("acme/secret-repo"), "repo slug (owner/repo) never reaches the LLM")
    let outputKeys = Set(ctx.facts.flatMap { $0.fields.keys })
    XCTAssertFalse(outputKeys.contains("repo"), "raw `repo` key never an output key")
    XCTAssertFalse(outputKeys.contains("title"), "raw `title` key never an output key")
  }

  // 21. `repo` is fenced in bodyFields (defense-in-depth, CR-14) so the
  //     unconditional bodies-fence test (11) backstops it.
  func testRepoIsFenced() {
    XCTAssertTrue(
      EgressFactAllowlist.bodyFields.contains("repo"),
      "repo (owner/repo slug) must be fenced — it is free text, not a dry fact")
  }

  // MARK: - P2 cluster 3b — cross_link_fact (event_links) projects structural refs only

  // 22. cross_link_fact: the structural link fields ship; a planted free-text key
  //     (repo / branch) on the same event is fenced. The `owner/repo`-never-ships
  //     guarantee for github_pr targets is enforced upstream (the gatherer's
  //     target_kind='linear_issue' filter) and proven in WorkFactGathererTests —
  //     `target_ref` is a trusted-value allow-listed key here.
  func testCrossLinkFactStructuralFieldsShip_freeTextFenced() {
    let ctx = policy.makeContext(events: [
      event(
        "cross_link_fact",
        [
          "from_kind": "gh_pr_review_comment_authored",
          "from_ref": "57",
          "link_kind": "linear_id_in_text",
          "target_kind": "linear_issue",
          "target_ref": "LEAF-88",
          "repo": "acme/secret-repo",  // free text — must NOT ship
          "branch": "feature/secret",  // free text — must NOT ship
        ])
    ])
    let r = rendered(ctx)
    XCTAssertTrue(r.contains("from_kind=gh_pr_review_comment_authored"), "source kind ships")
    XCTAssertTrue(r.contains("from_ref=57"), "from-side ref ships")
    XCTAssertTrue(r.contains("link_kind=linear_id_in_text"), "link kind ships")
    XCTAssertTrue(r.contains("target_ref=LEAF-88"), "Linear-issue target ref ships")
    XCTAssertFalse(r.contains("acme/secret-repo"), "repo slug fenced on cross_link_fact")
    XCTAssertFalse(r.contains("feature/secret"), "branch fenced on cross_link_fact")
    let outputKeys = Set(ctx.facts.flatMap { $0.fields.keys })
    XCTAssertTrue(
      outputKeys.isDisjoint(with: EgressFactAllowlist.bodyFields),
      "no fenced key projects on cross_link_fact")
  }
}
