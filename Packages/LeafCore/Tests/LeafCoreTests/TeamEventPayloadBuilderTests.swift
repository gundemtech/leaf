// Phase Track-5 S5 — TeamEventPayloadBuilder allowlist + truncation invariants.
// Includes ADR-010 walkback: banned-keys MUST NOT appear in any allowlist.

import XCTest
@testable import LeafCore

final class TeamEventPayloadBuilderTests: XCTestCase {

    func testGitCommitsAllowlist_OnlyKnownKeysCopied() {
        let payload: [String: String] = [
            "commit_sha": "abc123",
            "repo_full_name": "gundemtech/leaf",
            "branch": "feature/x",
            "body": "secret content NOT to be shared",   // banned — must drop
            "file_contents": "more secret",                // banned — must drop
            "commit_message_subject": "fix bug",
            "files_changed_count": "5"
        ]
        let built = TeamEventPayloadBuilder.build(source: .gitCommits, payload: payload)
        XCTAssertEqual(built.fields["commit_sha"], "abc123")
        XCTAssertEqual(built.fields["repo_full_name"], "gundemtech/leaf")
        XCTAssertEqual(built.fields["branch"], "feature/x")
        XCTAssertEqual(built.fields["commit_message_subject"], "fix bug")
        XCTAssertEqual(built.fields["files_changed_count"], "5")
        XCTAssertNil(built.fields["body"])
        XCTAssertNil(built.fields["file_contents"])
    }

    func testCommitMessageSubject_Truncated() {
        let long = String(repeating: "a", count: 500)
        let built = TeamEventPayloadBuilder.build(
            source: .gitCommits,
            payload: ["commit_message_subject": long]
        )
        XCTAssertEqual(built.fields["commit_message_subject"]?.count, 140)
    }

    func testLinearIssuesAllowlist() {
        let payload: [String: String] = [
            "issue_id": "i-1",
            "issue_identifier": "LEAF-99",
            "issue_title_excerpt": "feat: add X",
            "issue_state_type": "started",
            "team_key": "LEAF",
            "linear_comment_body": "raw comment text — banned"
        ]
        let built = TeamEventPayloadBuilder.build(source: .linearIssues, payload: payload)
        XCTAssertEqual(built.fields["issue_id"], "i-1")
        XCTAssertEqual(built.fields["issue_identifier"], "LEAF-99")
        XCTAssertNil(built.fields["linear_comment_body"])
    }

    func testSlackMentionsAllowlist() {
        let payload: [String: String] = [
            "channel_id_bucket": "DM",
            "has_mention_self": "true",
            "reactions_count": "3",
            "thread_root_ts": "1700000000.000100",
            "slack_message_text": "secret text — banned"
        ]
        let built = TeamEventPayloadBuilder.build(source: .slackMentions, payload: payload)
        XCTAssertEqual(built.fields["channel_id_bucket"], "DM")
        XCTAssertNil(built.fields["slack_message_text"])
    }

    func testGitHubPRsAllowlist() {
        let payload: [String: String] = [
            "pr_number": "142",
            "repo_full_name": "gundemtech/leaf",
            "pr_state": "merged",
            "pr_title_excerpt": "feat: add Y",
            "github_comment_body": "raw — banned"
        ]
        let built = TeamEventPayloadBuilder.build(source: .githubPRs, payload: payload)
        XCTAssertEqual(built.fields["pr_number"], "142")
        XCTAssertNil(built.fields["github_comment_body"])
    }

    func testDetectedDecisionsAllowlist() {
        let payload: [String: String] = [
            "topic_keywords_json": "[\"auth\"]",
            "reasoning_excerpt": String(repeating: "x", count: 500),
            "confidence_bucket": "high",
            "body": "banned"
        ]
        let built = TeamEventPayloadBuilder.build(source: .detectedDecisions, payload: payload)
        XCTAssertEqual(built.fields["reasoning_excerpt"]?.count, 200)
        XCTAssertNil(built.fields["body"])
    }

    func testDetectedBlockersAllowlist() {
        let payload: [String: String] = [
            "target_kind": "linear_issue",
            "target_ref": "LEAF-99",
            "blocker_kind": "linear_stuck",
            "blocker_excerpt": String(repeating: "z", count: 300)
        ]
        let built = TeamEventPayloadBuilder.build(source: .detectedBlockers, payload: payload)
        XCTAssertEqual(built.fields["blocker_excerpt"]?.count, 140)
    }

    func testRawGitHubActivityAllowlist() {
        let payload: [String: String] = [
            "action": "published",
            "ref_type": "tag",
            "ref_name": "v1.2.3",
            "repo_full_name": "gundemtech/leaf",
            "body": "release notes — banned"
        ]
        let built = TeamEventPayloadBuilder.build(source: .rawGitHubActivity, payload: payload)
        XCTAssertEqual(built.fields["action"], "published")
        XCTAssertEqual(built.fields["ref_type"], "tag")
        XCTAssertNil(built.fields["body"])
    }

    // MARK: - ADR-010 walkback

    func testBannedKeysNeverInAnyAllowlist() {
        for source in ShareSource.allCases {
            let allowed = TeamEventPayloadBuilder.allowedKeys(for: source)
            for banned in TeamEventPayloadBuilder.bannedKeys {
                XCTAssertFalse(allowed.contains(banned),
                               "source \(source.rawValue) allowlist must NOT contain banned key \(banned)")
            }
        }
    }
}
