import XCTest

@testable import LeafCore

final class EgressFactAllowlistTests: XCTestCase {
  /// CI guard (fail-closed proof): for a representative cross-provider event
  /// set salted with bodies / free-text / unknown keys, every projection OUTPUT
  /// key must belong to the declared allow-list. A new key reaching the cloud
  /// without being classified makes this fail.
  func testProjectionNeverExceedsDeclaredAllowlist() {
    let allowed = EgressFactAllowlist.scalarFacts
      .union(EgressFactAllowlist.derivedScalarFacts)
      .union(EgressFactAllowlist.selfAuthoredOutputKeys)
    let kinds = [
      "issue_updated", "gh_pr_opened", "gh_commit_pushed", "gh_branch_created",
      "gh_pr_review_comment_authored", "slack_message_authored_aggregate",
      "linear_comment_authored", "gh_issue_comment_authored", "unknown_future_kind",
      // P1 synthetic fact kinds (WorkFactGatherer)
      "recap_metrics", "blocker_fact", "open_question_fact", "where_stopped_fact",
    ]
    let payload: [String: String] = [
      "body": "x", "body_truncated": "true", "title": "x", "branch": "x",
      "channel_name": "x", "gist_description": "x", "note_title": "x", "meeting_topic": "x",
      "messages_json": "x", "thread_replies_json": "x", "comment_bodies_json": "x",
      "future_unknown_field": "x", "additions": "1", "issue_identifier": "LEA-1",
      "reaction_count": "2", "authored_by_viewer": "true",
      // P1 synthetic-fact keys (salted alongside free-text excerpts to prove fence)
      "focus_session_count": "1", "ai_ratio_pct": "30", "files_touched_count": "2",
      "target_kind": "github_pr", "target_ref": "PR-1", "blocker_kind": "awaiting_review",
      "linear_issue_ref": "LEA-1", "github_pr_ref": "PR-1", "slack_thread_ts": "1.2",
      "opened_at_ms": "1", "generated_at_ms": "1",
      "wip_commit": "true", "wip_ci_failing": "false", "wip_mid_edit": "true",
      "reasoning_excerpt": "x", "question_excerpt": "x", "blocker_excerpt": "x",
      "excerpt": "x", "window_title": "x", "files_touched": "/Users/a/secret.md",
    ]
    let policy = LLMPolicy()
    for kind in kinds {
      let event = EgressEvent(timestamp: Date(), kind: kind, bundleID: nil, payload: payload)
      for fact in policy.makeContext(events: [event]).facts {
        for key in fact.fields.keys {
          XCTAssertTrue(
            allowed.contains(key),
            "projection emitted un-allowlisted output key '\(key)' for kind '\(kind)'")
        }
      }
    }
  }

  func testSelfAuthoredOutputKeysMatchMapping() {
    let mapped = Set(EgressFactAllowlist.selfAuthored.values.map { $0.output })
    XCTAssertTrue(
      mapped.isSubset(of: EgressFactAllowlist.selfAuthoredOutputKeys),
      "every self-authored mapping output must be declared in selfAuthoredOutputKeys")
  }
}
