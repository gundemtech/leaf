//
//  TeamEventActionTextTests.swift
//  LeafCoreTests
//
//  M-IX — covers the action-text derivation moved out of LeafFeedRow.
//

import XCTest
@testable import LeafCore

final class TeamEventActionTextTests: XCTestCase {

    private func row(source: ShareSource, payloadJSON: String) -> TeamEventMirrorRow {
        TeamEventMirrorRow(
            eventID: "e1",
            workspaceID: "w1",
            senderPubkeyHex: "shex",
            source: source,
            kind: "k",
            plaintextPayloadJSON: payloadJSON,
            serverCreatedAtMs: 1,
            eventTsMs: 1,
            receivedAtMs: 1
        )
    }

    func testGitCommitsWithTitle() {
        XCTAssertEqual(
            TeamEventActionText.make(for: row(source: .gitCommits, payloadJSON: #"{"title":"Fix bug"}"#)),
            #"pushed "Fix bug""#
        )
    }

    func testGitCommitsFallback() {
        XCTAssertEqual(
            TeamEventActionText.make(for: row(source: .gitCommits, payloadJSON: "{}")),
            "pushed a commit"
        )
    }

    func testLinearIssuesWithTitle() {
        XCTAssertEqual(
            TeamEventActionText.make(for: row(source: .linearIssues, payloadJSON: #"{"title":"LEAF-1"}"#)),
            #"updated "LEAF-1""#
        )
    }

    func testLinearIssuesFallback() {
        XCTAssertEqual(
            TeamEventActionText.make(for: row(source: .linearIssues, payloadJSON: "{}")),
            "updated an issue"
        )
    }

    func testSlackMentionsConstant() {
        XCTAssertEqual(
            TeamEventActionText.make(for: row(source: .slackMentions, payloadJSON: #"{"title":"ignored"}"#)),
            "mentioned you"
        )
    }

    func testGithubPRsWithTitle() {
        XCTAssertEqual(
            TeamEventActionText.make(for: row(source: .githubPRs, payloadJSON: #"{"title":"Add cache"}"#)),
            #"opened PR "Add cache""#
        )
    }

    func testGithubPRsFallback() {
        XCTAssertEqual(
            TeamEventActionText.make(for: row(source: .githubPRs, payloadJSON: "{}")),
            "opened a pull request"
        )
    }

    func testDecisionWithExcerpt() {
        XCTAssertEqual(
            TeamEventActionText.make(for: row(source: .detectedDecisions, payloadJSON: #"{"reasoning_excerpt":"use SQLCipher"}"#)),
            "decision: use SQLCipher…"
        )
    }

    func testDecisionFallback() {
        XCTAssertEqual(
            TeamEventActionText.make(for: row(source: .detectedDecisions, payloadJSON: "{}")),
            "made a decision"
        )
    }

    func testBlockerWithExcerpt() {
        XCTAssertEqual(
            TeamEventActionText.make(for: row(source: .detectedBlockers, payloadJSON: #"{"blocker_excerpt":"waiting on relay"}"#)),
            "blocker: waiting on relay…"
        )
    }

    func testBlockerFallback() {
        XCTAssertEqual(
            TeamEventActionText.make(for: row(source: .detectedBlockers, payloadJSON: "{}")),
            "hit a blocker"
        )
    }

    func testQuestionWithExcerpt() {
        XCTAssertEqual(
            TeamEventActionText.make(for: row(source: .detectedOpenQuestions, payloadJSON: #"{"question_excerpt":"which port?"}"#)),
            "question: which port?…"
        )
    }

    func testQuestionFallback() {
        XCTAssertEqual(
            TeamEventActionText.make(for: row(source: .detectedOpenQuestions, payloadJSON: "{}")),
            "raised a question"
        )
    }

    func testWhereStoppedWithExcerpt() {
        XCTAssertEqual(
            TeamEventActionText.make(for: row(source: .detectedWhereStopped, payloadJSON: #"{"excerpt":"mid-refactor"}"#)),
            "stopped at: mid-refactor…"
        )
    }

    func testWhereStoppedFallback() {
        XCTAssertEqual(
            TeamEventActionText.make(for: row(source: .detectedWhereStopped, payloadJSON: "{}")),
            "stopped work"
        )
    }

    func testRawGitHubActivityConstant() {
        XCTAssertEqual(
            TeamEventActionText.make(for: row(source: .rawGitHubActivity, payloadJSON: #"{"title":"ignored"}"#)),
            "GitHub activity"
        )
    }

    func testExcerptTruncatedTo50() {
        let long = String(repeating: "x", count: 80)
        let out = TeamEventActionText.make(for: row(source: .detectedDecisions, payloadJSON: #"{"reasoning_excerpt":"\#(long)"}"#))
        XCTAssertEqual(out, "decision: \(String(repeating: "x", count: 50))…")
    }

    func testMalformedPayloadFallsBack() {
        XCTAssertEqual(
            TeamEventActionText.make(for: row(source: .gitCommits, payloadJSON: "not json")),
            "pushed a commit"
        )
    }

    // ADR-010: forbidden payload keys must never surface in the derived text.
    func testForbiddenKeysNeverSurface() {
        let payload = #"{"title":"Fix","body":"SECRET_BODY","ai_prompt":"LEAK_PROMPT","file_size":99999}"#
        let out = TeamEventActionText.make(for: row(source: .gitCommits, payloadJSON: payload))
        XCTAssertEqual(out, #"pushed "Fix""#)
        XCTAssertFalse(out.contains("SECRET_BODY"))
        XCTAssertFalse(out.contains("LEAK_PROMPT"))
        XCTAssertFalse(out.contains("99999"))
    }
}
