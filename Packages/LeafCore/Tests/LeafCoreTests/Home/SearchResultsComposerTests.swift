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

  private func event(
    _ id: Int64, ts: Int64, kind: String?, body: String?,
    ref: String? = nil, title: String? = nil
  ) -> ActivityEvent {
    ActivityEvent(
      eventID: id, tsMs: ts, signalType: "action", bundleID: nil,
      eventKind: kind, bodyExcerpt: body, bodyTruncated: false,
      targetRef: ref, targetTitle: title)
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

  func testEventRow_structuredTarget_headlineAndExcerpt() {
    let rows = SearchResultsComposer.compose(
      from: response(events: [
        event(
          1, ts: 1_000, kind: "issue_updated",
          body: "Что: внедрить дисциплину — каждая phase начинается с Linear issue.\n\nЗачем: substrate…",
          ref: "GUN-12", title: "Внедрить naming-дисциплину")
      ]))
    XCTAssertEqual(rows[0].title, "GUN-12 · Внедрить naming-дисциплину")
    XCTAssertTrue(rows[0].excerpt?.hasPrefix("Что: внедрить дисциплину") == true)
    XCTAssertFalse(rows[0].excerpt?.contains("\n") ?? true)
  }

  func testEventDedup_sameTargetCollapses_keepsNewest_counts() {
    // Capture-side re-emission: 5 identical issue_updated rows for one issue.
    let dupes = (1...5).map { i in
      event(
        Int64(i), ts: Int64(i * 100), kind: "issue_updated",
        body: "same body", ref: "GUN-12", title: "Same issue")
    }
    let rows = SearchResultsComposer.compose(
      from: response(events: dupes + [
        event(99, ts: 50, kind: "issue_updated", body: "other", ref: "GUN-13", title: "Other")
      ]))
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows[0].title, "GUN-12 · Same issue")
    XCTAssertEqual(rows[0].tsMs, 500)  // newest kept
    XCTAssertEqual(rows[0].occurrenceCount, 5)
    XCTAssertEqual(rows[1].occurrenceCount, 1)
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

// MARK: - Track B1 — presentation (count / MATCH / detail rows / noise)

extension SearchResultsComposerTests {

  private func decision(
    id: Int64 = 1, eventID: Int64 = 42, excerpt: String = "WAL is non-negotiable.",
    confidence: Double = 0.9, ts: Int64 = 5_000
  ) -> DecisionView {
    DecisionView(
      id: id, eventID: eventID, topicKeywords: ["queue"],
      reasoningExcerpt: excerpt, confidence: confidence, detectedAtMs: ts)
  }

  func testPresentation_CountLabelAndTopMatch() {
    let p = SearchResultsComposer.composePresentation(
      from: response(
        events: [event(7, ts: 9_000, kind: "gh_pr_opened", body: "queue refactor")],
        decisions: [decision()]))
    XCTAssertEqual(p.totalCount, 2)
    XCTAssertEqual(p.countLabel, "2 results")
    XCTAssertEqual(p.topMatchID, "decision:1", "MATCH badge goes to the top-ranked row")

    let single = SearchResultsComposer.composePresentation(
      from: response(decisions: [decision()]))
    XCTAssertEqual(single.countLabel, "1 result")
  }

  func testPresentation_NoiseEventsExcluded() {
    let p = SearchResultsComposer.composePresentation(
      from: response(events: [
        event(1, ts: 2_000, kind: "gh_pr_opened", body: "queue refactor"),
        event(2, ts: 3_000, kind: "gh_notifications_pulse", body: nil),
        event(3, ts: 4_000, kind: "claude_tokens_used", body: nil),
      ]))
    XCTAssertEqual(p.rows.count, 1)
    XCTAssertEqual(p.rows.first?.id, "event:1")
  }

  func testDecisionDetailRows_TicketPRAuthorChannelCommit() {
    let origin = ActivityEvent(
      eventID: 42, tsMs: 5_000, signalType: "action", bundleID: nil,
      eventKind: "slack_thread_reply_aggregate",
      bodyExcerpt: "WAL is non-negotiable.", bodyTruncated: false,
      channelName: "ios-architecture")
    let links = [
      LinkView(fromEventID: 42, linkKind: Schema.LinkKinds.linearIDInText,
               targetKind: Schema.TargetKinds.linearIssue, targetRef: "LEA-431", confidence: 0.8),
      LinkView(fromEventID: 42, linkKind: Schema.LinkKinds.prNumberHashRef,
               targetKind: Schema.TargetKinds.githubPR, targetRef: "acme/widget#142", confidence: 0.8),
      LinkView(fromEventID: 42, linkKind: Schema.LinkKinds.reviewerAssigned,
               targetKind: Schema.TargetKinds.githubUser, targetRef: "alexdev", confidence: 1.0),
    ]
    let p = SearchResultsComposer.composePresentation(
      from: response(events: [origin], decisions: [decision()], links: links))

    let detail = p.rows.first { $0.kind == .decision }?.detailRows ?? []
    let byLabel = Dictionary(uniqueKeysWithValues: detail.map { ($0.label, $0) })
    XCTAssertEqual(byLabel[.author]?.value, "alexdev")
    XCTAssertEqual(byLabel[.author]?.url?.absoluteString, "https://github.com/alexdev")
    XCTAssertEqual(byLabel[.channel]?.value, "#ios-architecture")
    XCTAssertEqual(byLabel[.ticket]?.value, "LEA-431")
    XCTAssertEqual(byLabel[.pr]?.value, "acme/widget#142")
    XCTAssertEqual(byLabel[.pr]?.url?.absoluteString, "https://github.com/acme/widget/pull/142")
  }

  func testDecisionDetailRows_CommitOrigin() {
    let origin = ActivityEvent(
      eventID: 42, tsMs: 5_000, signalType: "action", bundleID: nil,
      eventKind: "git_commit_authored",
      bodyExcerpt: "feat: move to async dispatch queue\n\nbody", bodyTruncated: false,
      targetRef: "acme/widget")
    let p = SearchResultsComposer.composePresentation(
      from: response(events: [origin], decisions: [decision()]))

    let detail = p.rows.first { $0.kind == .decision }?.detailRows ?? []
    XCTAssertEqual(detail.first { $0.label == .commit }?.value,
                   "feat: move to async dispatch queue · acme/widget")
  }
}

extension SearchResultsComposerTests {
  func testDecisionHeadline_LeadingBulletJunkStripped() {
    XCTAssertEqual(
      SearchResultsComposer.cleanDecisionHeadline("- Spec status APPROVED → SHIPPED."),
      "Spec status APPROVED → SHIPPED.")
    XCTAssertEqual(
      SearchResultsComposer.cleanDecisionHeadline("* fix(invite): atomic"),
      "fix(invite): atomic")
    XCTAssertEqual(
      SearchResultsComposer.cleanDecisionHeadline("plain decision text"),
      "plain decision text")
    XCTAssertEqual(SearchResultsComposer.cleanDecisionHeadline("---"), "---",
                   "all-junk excerpt falls back to the original")
  }
}
