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

/// One expandable line under a brief counter — "PR#61 · Use-case coverage…".
public struct BriefItem: Equatable, Hashable, Sendable, Identifiable {
  public let id: String
  /// "PR#61" / "GUN-12"
  public let ref: String
  /// PR / issue title when captured; nil → ref-only row.
  public let title: String?
  public let sourceURL: URL?

  public init(ref: String, title: String?, sourceURL: URL?) {
    self.id = ref
    self.ref = ref
    self.title = title
    self.sourceURL = sourceURL
  }
}

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
  /// Depth pass — expandable detail under the counters (capped at
  /// `BriefComposer.itemsCap`, newest first, deduplicated by ref).
  public let prItems: [BriefItem]
  public let ticketItems: [BriefItem]

  public var isEmpty: Bool {
    prsMerged == 0 && ticketsDone == 0 && decisionsSurfaced == 0
      && blockersResolved == 0 && commitsPushed == 0 && reviewsAuthored == 0
  }

  public init(
    periodDays: Int, prsMerged: Int, reposTouched: Int, ticketsDone: Int,
    decisionsSurfaced: Int, blockersResolved: Int, commitsPushed: Int,
    reviewsAuthored: Int, prItems: [BriefItem] = [], ticketItems: [BriefItem] = []
  ) {
    self.periodDays = periodDays
    self.prsMerged = prsMerged
    self.reposTouched = reposTouched
    self.ticketsDone = ticketsDone
    self.decisionsSurfaced = decisionsSurfaced
    self.blockersResolved = blockersResolved
    self.commitsPushed = commitsPushed
    self.reviewsAuthored = reviewsAuthored
    self.prItems = prItems
    self.ticketItems = ticketItems
  }
}

public enum BriefComposer {

  /// Expandable-detail cap per counter.
  public static let itemsCap = 10

  public static func compose(
    feed: [ActivityFeedItem],
    decisionsSurfaced: Int,
    blockersResolved: Int,
    periodDays: Int
  ) -> BriefSnapshot {
    let merged = feed.filter { $0.eventKind == "gh_pr_merged" }
    let repos = Set(merged.compactMap { $0.repoHint?.isEmpty == false ? $0.repoHint : nil })
    let done = feed.filter {
      $0.eventKind == LinearActivityKinds.statusTransitionCompletedKind
    }
    let commits = feed.count { $0.eventKind == "gh_commit_pushed" }
    let reviews = feed.count { $0.eventKind == GitHubActivityKinds.prReviewAuthoredKind }
    return BriefSnapshot(
      periodDays: periodDays,
      prsMerged: merged.count,
      reposTouched: repos.count,
      ticketsDone: done.count,
      decisionsSurfaced: decisionsSurfaced,
      blockersResolved: blockersResolved,
      commitsPushed: commits,
      reviewsAuthored: reviews,
      prItems: briefItems(from: merged),
      ticketItems: briefItems(from: done)
    )
  }

  /// Newest-first, deduplicated by ref, capped. Title falls back to nil when
  /// it merely repeats the ref (key-only rows pre-title-enrichment).
  static func briefItems(from feed: [ActivityFeedItem]) -> [BriefItem] {
    var seen = Set<String>()
    var items: [BriefItem] = []
    for item in feed.sorted(by: { $0.ts > $1.ts }) {
      guard items.count < itemsCap else { break }
      guard let ref = item.targetRef ?? item.targetTitle, !ref.isEmpty else { continue }
      guard seen.insert(ref).inserted else { continue }
      let title = item.targetTitle.flatMap { ($0.isEmpty || $0 == ref) ? nil : $0 }
      items.append(BriefItem(ref: ref, title: title, sourceURL: item.sourceURL))
    }
    return items
  }
}
