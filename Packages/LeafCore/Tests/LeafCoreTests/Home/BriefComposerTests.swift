//
//  BriefComposerTests.swift
//  UC-3 brief — "what shipped while I was out". Locks the count derivation
//  from the activity feed + detector counters.
//

import XCTest

@testable import LeafCore

final class BriefComposerTests: XCTestCase {

  private func feedItem(
    _ kind: String, ts: Int64 = 1, repoHint: String? = nil, actorIsMe: Bool = true
  ) -> ActivityFeedItem {
    ActivityFeedItem(
      ts: ts, source: kind.hasPrefix("gh_") ? .github : .linear, eventKind: kind,
      actorIsMe: actorIsMe, targetTitle: "t", targetRef: "r", repoHint: repoHint)
  }

  func testCounts_prsMergedAcrossRepos_ticketsDone() {
    let feed = [
      feedItem("gh_pr_merged", repoHint: "leaf"),
      feedItem("gh_pr_merged", repoHint: "leaf-relay"),
      feedItem("gh_pr_merged", repoHint: "leaf"),
      feedItem("gh_pr_opened", repoHint: "leaf"),
      feedItem(LinearActivityKinds.statusTransitionCompletedKind),
      feedItem(LinearActivityKinds.statusTransitionCompletedKind),
      feedItem(LinearActivityKinds.statusTransitionStartedKind),
    ]
    let brief = BriefComposer.compose(
      feed: feed, decisionsSurfaced: 3, blockersResolved: 1, periodDays: 5)
    XCTAssertEqual(brief.prsMerged, 3)
    XCTAssertEqual(brief.reposTouched, 2)
    XCTAssertEqual(brief.ticketsDone, 2)
    XCTAssertEqual(brief.decisionsSurfaced, 3)
    XCTAssertEqual(brief.blockersResolved, 1)
    XCTAssertFalse(brief.isEmpty)
  }

  func testItems_dedupedByRef_titleDropsRefEcho() {
    let feed = [
      ActivityFeedItem(
        ts: 3, source: .github, eventKind: "gh_pr_merged", actorIsMe: true,
        targetTitle: "Use-case coverage", targetRef: "PR#61", repoHint: "leaf",
        sourceURL: URL(string: "https://github.com/x/leaf/pull/61")),
      ActivityFeedItem(
        ts: 2, source: .github, eventKind: "gh_pr_merged", actorIsMe: true,
        targetTitle: "Use-case coverage", targetRef: "PR#61", repoHint: "leaf"),
      ActivityFeedItem(
        ts: 1, source: .linear,
        eventKind: LinearActivityKinds.statusTransitionCompletedKind, actorIsMe: true,
        targetTitle: "GUN-31", targetRef: "GUN-31"),
    ]
    let brief = BriefComposer.compose(
      feed: feed, decisionsSurfaced: 0, blockersResolved: 0, periodDays: 5)
    XCTAssertEqual(brief.prItems.count, 1)
    XCTAssertEqual(brief.prItems[0].ref, "PR#61")
    XCTAssertEqual(brief.prItems[0].title, "Use-case coverage")
    XCTAssertNotNil(brief.prItems[0].sourceURL)
    XCTAssertEqual(brief.ticketItems.count, 1)
    XCTAssertNil(brief.ticketItems[0].title, "title echoing the ref must drop to nil")
  }

  func testEmpty_allZero() {
    let brief = BriefComposer.compose(
      feed: [], decisionsSurfaced: 0, blockersResolved: 0, periodDays: 5)
    XCTAssertTrue(brief.isEmpty)
  }

  func testCommitsAndReviews_secondaryCounts() {
    let feed = [
      feedItem("gh_commit_pushed", repoHint: "leaf"),
      feedItem("gh_commit_pushed", repoHint: "leaf"),
      feedItem(GitHubActivityKinds.prReviewAuthoredKind, repoHint: "leaf"),
    ]
    let brief = BriefComposer.compose(
      feed: feed, decisionsSurfaced: 0, blockersResolved: 0, periodDays: 5)
    XCTAssertEqual(brief.commitsPushed, 2)
    XCTAssertEqual(brief.reviewsAuthored, 1)
    XCTAssertFalse(brief.isEmpty)
  }
}

// MARK: - Track B3 — team aggregation + detail composer

extension BriefComposerTests {

  private func mirrorRow(
    kind: String, sender: String, payload: [String: Any], ts: Int64 = 1_000
  ) -> TeamEventMirrorRow {
    let json = String(
      data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
    return TeamEventMirrorRow(
      eventID: UUID().uuidString, workspaceID: "ws", senderPubkeyHex: sender,
      source: .githubPRs, kind: kind, plaintextPayloadJSON: json,
      serverCreatedAtMs: ts, eventTsMs: ts, receivedAtMs: ts)
  }

  func testTeamAggregation_CountsTeammatesAndDedupsSelfMirror() {
    let localFeed = [
      ActivityFeedItem(
        ts: 1, source: .github, eventKind: "gh_pr_merged", actorIsMe: true,
        targetTitle: "Local PR", targetRef: "acme/widget#61", repoHint: "acme/widget")
    ]
    let teamRows = [
      // Own event mirrored back — must NOT double-count (pubkey filter).
      mirrorRow(kind: "gh_pr_merged", sender: "me",
                payload: ["repo_full_name": "acme/widget", "pr_number": "61"]),
      // Teammate's PR in another repo.
      mirrorRow(kind: "gh_pr_merged", sender: "alex",
                payload: ["repo_full_name": "acme/gadget", "pr_number": "9",
                          "pr_title_excerpt": "Relay retry"]),
      // Teammate's completed ticket.
      mirrorRow(kind: "status_transition", sender: "alex",
                payload: ["issue_identifier": "LEA-431", "issue_state_type": "completed",
                          "issue_title_excerpt": "Queue cutover"]),
      // Non-completed transition — not "done".
      mirrorRow(kind: "status_transition", sender: "alex",
                payload: ["issue_identifier": "LEA-432", "issue_state_type": "started"]),
    ]
    let team = teamRows.compactMap(TeamBriefEvent.from)

    let brief = BriefComposer.compose(
      feed: localFeed, teamEvents: team, selfPubkeyHex: "me",
      decisionsSurfaced: 0, blockersResolved: 0, periodDays: 5)

    XCTAssertEqual(brief.prsMerged, 2, "local + teammate, self-mirror deduped")
    XCTAssertEqual(brief.reposTouched, 2)
    XCTAssertEqual(brief.ticketsDone, 1)
    XCTAssertEqual(brief.contributorCount, 2, "me + alex")
    XCTAssertTrue(brief.prItems.contains { $0.ref == "acme/gadget#9" && $0.title == "Relay retry" })
    XCTAssertTrue(brief.ticketItems.contains { $0.ref == "LEA-431" })
  }

  func testResolutionNote_WeekdayOfLatestResolution() {
    // 2026-06-09 was a Tuesday.
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let tuesdayMs: Int64 = 1_781_001_600_000  // 2026-06-09 16:00 UTC
    let note = BriefComposer.resolutionNote([tuesdayMs], calendar: cal)
    XCTAssertEqual(note, "resolved by Tuesday")
    XCTAssertNil(BriefComposer.resolutionNote([]))
  }

  func testBriefDetail_SectionsOmitEmpty() {
    let snapshot = BriefSnapshot(
      periodDays: 5, prsMerged: 1, reposTouched: 1, ticketsDone: 0,
      decisionsSurfaced: 1, blockersResolved: 0, commitsPushed: 0,
      reviewsAuthored: 0,
      prItems: [BriefItem(ref: "a/b#1", title: "One", sourceURL: nil)])
    let decision = DecisionView(
      id: 7, eventID: 42, topicKeywords: [], reasoningExcerpt: "WAL is non-negotiable.",
      confidence: 0.9, detectedAtMs: 1_000)

    let detail = BriefDetailComposer.compose(snapshot: snapshot, decisions: [decision], blockers: [])
    XCTAssertEqual(detail.sections.map(\.title), ["PRS MERGED", "DECISIONS SURFACED"])
    XCTAssertEqual(detail.sections[1].items.first?.title, "WAL is non-negotiable.")
  }
}
