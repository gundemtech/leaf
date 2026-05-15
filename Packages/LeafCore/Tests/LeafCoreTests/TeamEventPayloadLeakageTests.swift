// Phase Track-5 S5 — ADR-010 walkback fence for auto-shared team-event
// payloads. Mirrors RelayBodyLeakageTests intent: pump synthetic payloads
// loaded with banned-key sentinels through the TeamEventPayloadBuilder; assert
// the sentinels never appear in the output.

import XCTest
@testable import LeafCore

final class TeamEventPayloadLeakageTests: XCTestCase {

    // MARK: - Sentinel walks per source

    func testCommitsAllowlist_StripsAllBannedKeys() {
        let payload: [String: String] = [
            "commit_sha": "abc",
            "body": "SECRET-COMMIT-BODY",
            "file_contents": "SECRET-FILE-CONTENTS",
            "note_body": "SECRET-NOTE-BODY",
            "email_subject": "SECRET-EMAIL-SUBJECT",
            "preview": "SECRET-PREVIEW",
            "prompt": "SECRET-PROMPT",
            "response": "SECRET-RESPONSE",
            "slack_message_text": "SECRET-SLACK-TEXT",
            "linear_comment_body": "SECRET-LINEAR-COMMENT",
            "github_comment_body": "SECRET-GITHUB-COMMENT",
            "slack_canvas_content": "SECRET-SLACK-CANVAS"
        ]
        let built = TeamEventPayloadBuilder.build(source: .gitCommits, payload: payload)
        assertNoSentinels(in: built)
    }

    func testLinearAllowlist_StripsAllBannedKeys() {
        let payload: [String: String] = [
            "issue_identifier": "LEAF-99",
            "body": "SECRET-1",
            "linear_comment_body": "SECRET-2",
            "preview": "SECRET-3"
        ]
        let built = TeamEventPayloadBuilder.build(source: .linearIssues, payload: payload)
        assertNoSentinels(in: built)
    }

    func testSlackAllowlist_StripsAllBannedKeys() {
        let payload: [String: String] = [
            "channel_id_bucket": "DM",
            "slack_message_text": "SECRET-1",
            "slack_canvas_content": "SECRET-2",
            "body": "SECRET-3"
        ]
        let built = TeamEventPayloadBuilder.build(source: .slackMentions, payload: payload)
        assertNoSentinels(in: built)
    }

    func testGitHubPRsAllowlist_StripsAllBannedKeys() {
        let payload: [String: String] = [
            "pr_number": "142",
            "github_comment_body": "SECRET-1",
            "body": "SECRET-2",
            "preview": "SECRET-3"
        ]
        let built = TeamEventPayloadBuilder.build(source: .githubPRs, payload: payload)
        assertNoSentinels(in: built)
    }

    func testDetectedDecisionsAllowlist_StripsAllBannedKeys() {
        let payload: [String: String] = [
            "topic_keywords_json": "[\"auth\"]",
            "reasoning_excerpt": "valid excerpt",
            "confidence_bucket": "high",
            "body": "SECRET-1",
            "prompt": "SECRET-2",
            "response": "SECRET-3"
        ]
        let built = TeamEventPayloadBuilder.build(source: .detectedDecisions, payload: payload)
        assertNoSentinels(in: built)
    }

    func testDetectedBlockersAllowlist_StripsAllBannedKeys() {
        let payload: [String: String] = [
            "target_kind": "linear_issue",
            "target_ref": "LEAF-99",
            "blocker_kind": "linear_stuck",
            "blocker_excerpt": "valid excerpt",
            "body": "SECRET",
            "note_body": "SECRET2"
        ]
        let built = TeamEventPayloadBuilder.build(source: .detectedBlockers, payload: payload)
        assertNoSentinels(in: built)
    }

    func testDetectedOpenQuestionsAllowlist_StripsAllBannedKeys() {
        let payload: [String: String] = [
            "question_excerpt": "valid",
            "alternatives_count": "3",
            "context_kind": "slack",
            "body": "SECRET",
            "preview": "SECRET2"
        ]
        let built = TeamEventPayloadBuilder.build(source: .detectedOpenQuestions, payload: payload)
        assertNoSentinels(in: built)
    }

    func testDetectedWhereStoppedAllowlist_StripsAllBannedKeys() {
        let payload: [String: String] = [
            "excerpt": "valid",
            "wip_signal_count": "5",
            "body": "SECRET",
            "file_contents": "SECRET2"
        ]
        let built = TeamEventPayloadBuilder.build(source: .detectedWhereStopped, payload: payload)
        assertNoSentinels(in: built)
    }

    func testRawGitHubActivityAllowlist_StripsAllBannedKeys() {
        let payload: [String: String] = [
            "action": "published",
            "ref_type": "tag",
            "body": "SECRET",
            "response": "SECRET2"
        ]
        let built = TeamEventPayloadBuilder.build(source: .rawGitHubActivity, payload: payload)
        assertNoSentinels(in: built)
    }

    // MARK: - DefaultDenyList path-based + size-based walkback

    func testDenyList_DropsEnvPath() {
        let denyList = DefaultDenyList()
        XCTAssertTrue(denyList.matches(
            eventKind: "gh_commit_pushed",
            payload: ["file_path": "/home/.env", "commit_sha": "abc"]
        ))
    }

    func testDenyList_DropsLargeFile() {
        let denyList = DefaultDenyList()
        XCTAssertTrue(denyList.matches(
            eventKind: "gh_commit_pushed",
            payload: ["file_size": "200000000"]
        ))
    }

    func testDenyList_DropsAIKind() {
        let denyList = DefaultDenyList()
        XCTAssertTrue(denyList.matches(
            eventKind: "ai_prompt_submitted",
            payload: [:]
        ))
    }

    func testDenyList_DropsCredentialsPath() {
        let denyList = DefaultDenyList()
        XCTAssertTrue(denyList.matches(
            eventKind: "gh_commit_pushed",
            payload: ["file_path": "/home/.aws/credentials"]
        ))
    }

    // MARK: - Helpers

    private func assertNoSentinels(in payload: TeamEventPayload, file: StaticString = #filePath, line: UInt = #line) {
        for (key, value) in payload.fields {
            XCTAssertFalse(
                TeamEventPayloadBuilder.bannedKeys.contains(key),
                "banned key \(key) leaked into payload",
                file: file, line: line
            )
            // Defensive: also check value strings for SECRET- markers (test fixtures
            // only use SECRET- prefix). If the prefix appears in a value, an
            // allow-listed key accidentally absorbed a banned-key value.
            XCTAssertFalse(
                value.hasPrefix("SECRET-"),
                "value \(value) on key \(key) leaked from banned key",
                file: file, line: line
            )
        }
    }
}
