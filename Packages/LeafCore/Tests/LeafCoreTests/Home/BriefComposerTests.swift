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
