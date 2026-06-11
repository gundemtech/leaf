//
//  SearchResultsComposerTests.swift
//  UC-1 in-app search — locks the composition contract: QueryEngine responses
//  (decisions / open questions / blockers / FTS events + link graph) →
//  display rows for the Search screen. Decisions rank first (the landing
//  promise is "find the thread that explains why"), then detector hits,
//  then raw events, each newest-first.
//

import XCTest

@testable import LeafCore

final class SearchResultsComposerTests: XCTestCase {

  private func event(_ id: Int64, ts: Int64, kind: String?, body: String?) -> ActivityEvent {
    ActivityEvent(
      eventID: id, tsMs: ts, signalType: "action", bundleID: nil,
      eventKind: kind, bodyExcerpt: body, bodyTruncated: false)
  }

  private func response(
    events: [ActivityEvent] = [],
    decisions: [DecisionView] = [],
    questions: [OpenQuestionView] = [],
    blockers: [BlockerView] = [],
    links: [LinkView] = []
  ) -> QueryActivityResponse {
    QueryActivityResponse(
      period: PeriodSpec(startMs: 0, endMs: 10_000),
      filter: "queue",
      events: events,
      decisionsInPeriod: decisions,
      openQuestions: questions,
      blockers: blockers,
      links: links,
      absenceFlags: [],
      truncationNote: nil)
  }

  func testDecisionsRankFirst_withLinksAttached() {
    let decision = DecisionView(
      id: 1, eventID: 42, topicKeywords: ["queue", "dispatch"],
      reasoningExcerpt: "WAL is non-negotiable for our migration story.",
      confidence: 0.9, detectedAtMs: 5_000)
    let link = LinkView(
      fromEventID: 42, linkKind: "mentions", targetKind: "github_pr",
      targetRef: "leaf/core/12", confidence: 0.8)
    let strayLink = LinkView(
      fromEventID: 99, linkKind: "mentions", targetKind: "linear_issue",
      targetRef: "LEA-1", confidence: 0.8)
    let rows = SearchResultsComposer.compose(
      from: response(
        events: [event(7, ts: 9_000, kind: "gh_pr_opened", body: "queue refactor")],
        decisions: [decision],
        links: [link, strayLink]))

    XCTAssertEqual(rows.first?.kind, .decision)
    XCTAssertEqual(rows.first?.title, "WAL is non-negotiable for our migration story.")
    XCTAssertEqual(rows.first?.links, [link])
  }

  func testEventRow_titleFromBodyExcerpt_fallbackEventKind() {
    let rows = SearchResultsComposer.compose(
      from: response(events: [
        event(1, ts: 2_000, kind: "gh_pr_opened", body: nil),
        event(2, ts: 1_000, kind: "issue_updated", body: "Fix relay reconnect"),
      ]))
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows[0].title, "gh_pr_opened")
    XCTAssertEqual(rows[1].title, "Fix relay reconnect")
  }

  func testOrdering_decisions_thenDetectors_thenEvents_newestFirstWithinGroup() {
    let d = DecisionView(
      id: 1, eventID: 1, topicKeywords: [], reasoningExcerpt: "decided",
      confidence: 0.5, detectedAtMs: 100)
    let q = OpenQuestionView(
      id: 2, eventID: 2, questionExcerpt: "which KDF?", alternatives: nil,
      slackThreadTS: nil, linearIssueRef: nil, githubPRRef: nil,
      resolvedByEventID: nil, openedAtMs: 9_999, resolvedAtMs: nil)
    let rows = SearchResultsComposer.compose(
      from: response(
        events: [
          event(3, ts: 1_000, kind: "a", body: "older"),
          event(4, ts: 2_000, kind: "b", body: "newer"),
        ],
        decisions: [d], questions: [q]))
    XCTAssertEqual(rows.map(\.kind), [.decision, .openQuestion, .event, .event])
    XCTAssertEqual(rows[2].title, "newer")
  }

  func testDecisionsSortedByConfidenceThenRecency() {
    let weak = DecisionView(
      id: 1, eventID: 1, topicKeywords: [], reasoningExcerpt: "weak",
      confidence: 0.3, detectedAtMs: 9_000)
    let strong = DecisionView(
      id: 2, eventID: 2, topicKeywords: [], reasoningExcerpt: "strong",
      confidence: 0.9, detectedAtMs: 1_000)
    let rows = SearchResultsComposer.compose(
      from: response(decisions: [weak, strong]))
    XCTAssertEqual(rows.map(\.title), ["strong", "weak"])
  }

  func testSourceLabel_fromEventKindPrefix() {
    XCTAssertEqual(SearchResultsComposer.sourceLabel(eventKind: "gh_pr_opened"), "GitHub")
    XCTAssertEqual(SearchResultsComposer.sourceLabel(eventKind: "linear_comment_authored"), "Linear")
    XCTAssertEqual(SearchResultsComposer.sourceLabel(eventKind: "issue_updated"), "Linear")
    XCTAssertEqual(SearchResultsComposer.sourceLabel(eventKind: "slack_message_authored"), "Slack")
    XCTAssertEqual(SearchResultsComposer.sourceLabel(eventKind: "claude_session_start"), "AI")
    XCTAssertEqual(SearchResultsComposer.sourceLabel(eventKind: nil), "Local")
  }

  func testEmptyResponse_emptyRows() {
    XCTAssertTrue(SearchResultsComposer.compose(from: response()).isEmpty)
  }
}
