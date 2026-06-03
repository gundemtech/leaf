// Phase Track-5 S5 — ShareSourceClassifier golden table + nil cases.

import XCTest
@testable import LeafCore

final class ShareSourceClassifierTests: XCTestCase {
    private let classifier = ShareSourceClassifier()

    func testGitCommitMapping() {
        XCTAssertEqual(classifier.classify(eventKind: "gh_commit_pushed"), .gitCommits)
    }

    func testLinearIssueMapping() {
        XCTAssertEqual(classifier.classify(eventKind: "issue_updated"), .linearIssues)
        XCTAssertEqual(classifier.classify(eventKind: "linear_status_transition"), .linearIssues)
        XCTAssertEqual(classifier.classify(eventKind: "linear_priority_changed"), .linearIssues)
        XCTAssertEqual(classifier.classify(eventKind: "linear_label_added"), .linearIssues)
        XCTAssertEqual(classifier.classify(eventKind: "linear_label_removed"), .linearIssues)
        XCTAssertEqual(classifier.classify(eventKind: "linear_assignee_changed"), .linearIssues)
        XCTAssertEqual(classifier.classify(eventKind: "linear_cycle_changed"), .linearIssues)
        XCTAssertEqual(classifier.classify(eventKind: "linear_estimate_changed"), .linearIssues)
        XCTAssertEqual(classifier.classify(eventKind: "linear_comment_authored"), .linearIssues)
        XCTAssertEqual(classifier.classify(eventKind: "linear_project_update_authored"), .linearIssues)
    }

    func testSlackMentionMapping() {
        XCTAssertEqual(classifier.classify(eventKind: "slack_message_authored_aggregate"), .slackMentions)
        XCTAssertEqual(classifier.classify(eventKind: "slack_thread_reply_aggregate"), .slackMentions)
        XCTAssertEqual(classifier.classify(eventKind: "slack_mention_received"), .slackMentions)
    }

    func testGitHubPRMapping() {
        XCTAssertEqual(classifier.classify(eventKind: "gh_pr_opened"), .githubPRs)
        XCTAssertEqual(classifier.classify(eventKind: "gh_pr_merged"), .githubPRs)
        XCTAssertEqual(classifier.classify(eventKind: "gh_pr_closed"), .githubPRs)
        XCTAssertEqual(classifier.classify(eventKind: "gh_pr_review_submitted"), .githubPRs)
        XCTAssertEqual(classifier.classify(eventKind: "gh_pr_review_comment_authored"), .githubPRs)
        XCTAssertEqual(classifier.classify(eventKind: "gh_pr_review_thread_resolved"), .githubPRs)
    }

    func testDetectionMapping() {
        XCTAssertEqual(classifier.classify(eventKind: "decision_detected"), .detectedDecisions)
        XCTAssertEqual(classifier.classify(eventKind: "blocker_started"), .detectedBlockers)
        XCTAssertEqual(classifier.classify(eventKind: "blocker_resolved"), .detectedBlockers)
        XCTAssertEqual(classifier.classify(eventKind: "open_question_opened"), .detectedOpenQuestions)
        XCTAssertEqual(classifier.classify(eventKind: "open_question_resolved"), .detectedOpenQuestions)
        XCTAssertEqual(classifier.classify(eventKind: "where_stopped_snapshot"), .detectedWhereStopped)
    }

    func testRawGitHubActivityMapping() {
        XCTAssertEqual(classifier.classify(eventKind: "gh_branch_created"), .rawGitHubActivity)
        XCTAssertEqual(classifier.classify(eventKind: "gh_branch_deleted"), .rawGitHubActivity)
        XCTAssertEqual(classifier.classify(eventKind: "gh_tag_created"), .rawGitHubActivity)
        XCTAssertEqual(classifier.classify(eventKind: "gh_release_published"), .rawGitHubActivity)
        XCTAssertEqual(classifier.classify(eventKind: "gh_discussion_authored"), .rawGitHubActivity)
        XCTAssertEqual(classifier.classify(eventKind: "gh_discussion_comment_authored"), .rawGitHubActivity)
        XCTAssertEqual(classifier.classify(eventKind: "gh_issue_comment_authored"), .rawGitHubActivity)
    }

    func testUnclassifiedEventsReturnNil() {
        XCTAssertNil(classifier.classify(eventKind: "active_app_changed"))
        XCTAssertNil(classifier.classify(eventKind: "idle_state_changed"))
        XCTAssertNil(classifier.classify(eventKind: "intensity_snapshot"))
        XCTAssertNil(classifier.classify(eventKind: "focus_mode_enabled"))
        XCTAssertNil(classifier.classify(eventKind: "meeting_state_entered"))
        XCTAssertNil(classifier.classify(eventKind: "music_track_changed"))
    }

    func testIDEWorkspaceKindsAreLocalOnly() {
        // Settings dead-toggle remediation (WS1): the IDE workspace watchers
        // emit these kinds, but there is no IDE ShareSource — they are LOCAL-only
        // (Native UI / MCP / YOU·NOW) and must never be auto-shareable. classify()
        // returning nil → TeamEventBroadcastService skips them (.skip "unmapped").
        XCTAssertNil(classifier.classify(eventKind: "vscode_workspace_opened"))
        XCTAssertNil(classifier.classify(eventKind: "jetbrains_recent_project_observed"))
        XCTAssertFalse(ShareSourceClassifier.knownEventKinds.contains("vscode_workspace_opened"))
        XCTAssertFalse(
            ShareSourceClassifier.knownEventKinds.contains("jetbrains_recent_project_observed"))
    }

    func testAIContentKindsNotClassified() {
        // Defense in depth — even if such a kind existed, it must not be auto-shareable.
        XCTAssertNil(classifier.classify(eventKind: "ai_prompt_submitted"))
        XCTAssertNil(classifier.classify(eventKind: "ai_response_streamed"))
    }

    func testKnownEventKindsIncludesAll() {
        let known = ShareSourceClassifier.knownEventKinds
        XCTAssertGreaterThanOrEqual(known.count, 32)
        XCTAssertTrue(known.contains("gh_commit_pushed"))
        XCTAssertTrue(known.contains("decision_detected"))
        XCTAssertFalse(known.contains("active_app_changed"))
    }
}
