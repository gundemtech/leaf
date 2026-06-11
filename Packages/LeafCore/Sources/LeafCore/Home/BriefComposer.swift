//
//  BriefComposer.swift
//  UC-3 brief — "what shipped while I was out", the landing's Monday-brief
//  card. Pure count derivation from the activity feed + detector counters;
//  the reader supplies inputs, the SwiftUI body renders the snapshot.
//
//  v1 scope: local memory (own activity). For a solo install self == team;
//  team-mirror aggregation (counting teammates' shared events) is the
//  follow-up — needs workspace + identity wiring in the reader.
//

import Foundation

public struct BriefSnapshot: Equatable, Hashable, Sendable {
  public let periodDays: Int
  public let prsMerged: Int
  /// Distinct repos among merged PRs — "12 PRs merged across 4 repos".
  public let reposTouched: Int
  public let ticketsDone: Int
  public let decisionsSurfaced: Int
  public let blockersResolved: Int
  public let commitsPushed: Int
  public let reviewsAuthored: Int

  public var isEmpty: Bool {
    prsMerged == 0 && ticketsDone == 0 && decisionsSurfaced == 0
      && blockersResolved == 0 && commitsPushed == 0 && reviewsAuthored == 0
  }

  public init(
    periodDays: Int, prsMerged: Int, reposTouched: Int, ticketsDone: Int,
    decisionsSurfaced: Int, blockersResolved: Int, commitsPushed: Int,
    reviewsAuthored: Int
  ) {
    self.periodDays = periodDays
    self.prsMerged = prsMerged
    self.reposTouched = reposTouched
    self.ticketsDone = ticketsDone
    self.decisionsSurfaced = decisionsSurfaced
    self.blockersResolved = blockersResolved
    self.commitsPushed = commitsPushed
    self.reviewsAuthored = reviewsAuthored
  }
}

public enum BriefComposer {

  public static func compose(
    feed: [ActivityFeedItem],
    decisionsSurfaced: Int,
    blockersResolved: Int,
    periodDays: Int
  ) -> BriefSnapshot {
    let merged = feed.filter { $0.eventKind == "gh_pr_merged" }
    let repos = Set(merged.compactMap { $0.repoHint?.isEmpty == false ? $0.repoHint : nil })
    let ticketsDone = feed.count {
      $0.eventKind == LinearActivityKinds.statusTransitionCompletedKind
    }
    let commits = feed.count { $0.eventKind == "gh_commit_pushed" }
    let reviews = feed.count { $0.eventKind == GitHubActivityKinds.prReviewAuthoredKind }
    return BriefSnapshot(
      periodDays: periodDays,
      prsMerged: merged.count,
      reposTouched: repos.count,
      ticketsDone: ticketsDone,
      decisionsSurfaced: decisionsSurfaced,
      blockersResolved: blockersResolved,
      commitsPushed: commits,
      reviewsAuthored: reviews
    )
  }
}
