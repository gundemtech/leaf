import XCTest

@testable import LeafCore

final class EgressFactAllowlistTests: XCTestCase {
  /// CI guard (fail-closed proof): for a representative cross-provider event
  /// set salted with bodies / free-text / unknown keys, every projection OUTPUT
  /// key must belong to the declared allow-list. A new key reaching the cloud
  /// without being classified makes this fail.
  func testProjectionNeverExceedsDeclaredAllowlist() {
    let allowed = EgressFactAllowlist.scalarFacts.union(EgressFactAllowlist.selfAuthoredOutputKeys)
    let kinds = [
      "issue_updated", "gh_pr_opened", "gh_commit_pushed", "gh_branch_created",
      "gh_pr_review_comment_authored", "slack_message_authored_aggregate",
      "linear_comment_authored", "gh_issue_comment_authored", "unknown_future_kind",
    ]
    let payload: [String: String] = [
      "body": "x", "body_truncated": "true", "title": "x", "branch": "x",
      "channel_name": "x", "gist_description": "x", "note_title": "x", "meeting_topic": "x",
      "messages_json": "x", "thread_replies_json": "x", "comment_bodies_json": "x",
      "future_unknown_field": "x", "additions": "1", "issue_identifier": "LEA-1",
      "reaction_count": "2", "authored_by_viewer": "true",
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
