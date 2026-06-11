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
  /// Track B3 — distinct people behind the counters (self + teammates whose
  /// mirrored events contributed). 0 on a solo install with no activity.
  public let contributorCount: Int
  /// Track B3 — "resolved by Tuesday" copy for the blockers line (weekday of
  /// the latest resolution inside the period); nil when none resolved.
  public let blockerResolutionNote: String?

  public var isEmpty: Bool {
    prsMerged == 0 && ticketsDone == 0 && decisionsSurfaced == 0
      && blockersResolved == 0 && commitsPushed == 0 && reviewsAuthored == 0
  }

  public init(
    periodDays: Int, prsMerged: Int, reposTouched: Int, ticketsDone: Int,
    decisionsSurfaced: Int, blockersResolved: Int, commitsPushed: Int,
    reviewsAuthored: Int, prItems: [BriefItem] = [], ticketItems: [BriefItem] = [],
    contributorCount: Int = 0, blockerResolutionNote: String? = nil
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
    self.contributorCount = contributorCount
    self.blockerResolutionNote = blockerResolutionNote
  }
}

public enum BriefComposer {

  /// Expandable-detail cap per counter.
  public static let itemsCap = 10

  public static func compose(
    feed: [ActivityFeedItem],
    teamEvents: [TeamBriefEvent] = [],
    selfPubkeyHex: String? = nil,
    decisionsSurfaced: Int,
    blockersResolved: Int,
    blockerResolvedAtMs: [Int64] = [],
    periodDays: Int
  ) -> BriefSnapshot {
    // Track B3 — own events come back mirrored too; the pubkey filter is the
    // double-count guard.
    let teammates = teamEvents.filter { $0.senderPubkeyHex != (selfPubkeyHex ?? "") }

    let merged = feed.filter { $0.eventKind == "gh_pr_merged" }
    let localMergedRefs = Set(merged.compactMap(\.targetRef))
    let teamMerged = teammates.filter { $0.kind == "gh_pr_merged" }
      .filter { $0.ref == nil || !localMergedRefs.contains($0.ref!) }
    let repos = Set(
      merged.compactMap { $0.repoHint?.isEmpty == false ? $0.repoHint : nil }
        + teamMerged.compactMap(\.repoHint))

    let done = feed.filter {
      $0.eventKind == LinearActivityKinds.statusTransitionCompletedKind
    }
    let localDoneRefs = Set(done.compactMap(\.targetRef))
    let teamDone = teammates.filter { $0.kind != "gh_pr_merged" }
      .filter { $0.ref == nil || !localDoneRefs.contains($0.ref!) }

    let commits = feed.count { $0.eventKind == "gh_commit_pushed" }
    let reviews = feed.count { $0.eventKind == GitHubActivityKinds.prReviewAuthoredKind }

    let contributingSenders = Set((teamMerged + teamDone).map(\.senderPubkeyHex))
    let selfContributes = !merged.isEmpty || !done.isEmpty || commits > 0 || reviews > 0
    let contributors = contributingSenders.count + (selfContributes ? 1 : 0)

    return BriefSnapshot(
      periodDays: periodDays,
      prsMerged: merged.count + teamMerged.count,
      reposTouched: repos.count,
      ticketsDone: done.count + teamDone.count,
      decisionsSurfaced: decisionsSurfaced,
      blockersResolved: blockersResolved,
      commitsPushed: commits,
      reviewsAuthored: reviews,
      prItems: mergeItems(briefItems(from: merged), teamItems(teamMerged)),
      ticketItems: mergeItems(briefItems(from: done), teamItems(teamDone)),
      contributorCount: contributors,
      blockerResolutionNote: resolutionNote(blockerResolvedAtMs)
    )
  }

  /// "resolved by Tuesday" — weekday of the latest resolution.
  static func resolutionNote(_ resolvedAtMs: [Int64], calendar: Calendar = .current) -> String? {
    guard let latest = resolvedAtMs.max() else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.dateFormat = "EEEE"
    let day = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(latest) / 1000))
    return "resolved by \(day)"
  }

  static func teamItems(_ events: [TeamBriefEvent]) -> [BriefItem] {
    events.sorted { $0.tsMs > $1.tsMs }.compactMap { e in
      guard let ref = e.ref else { return nil }
      return BriefItem(ref: ref, title: e.title, sourceURL: nil)
    }
  }

  /// Local + team detail items, deduplicated by ref, newest-ish order
  /// preserved (local first — they carry source URLs), capped.
  static func mergeItems(_ local: [BriefItem], _ team: [BriefItem]) -> [BriefItem] {
    var seen = Set<String>()
    var out: [BriefItem] = []
    for item in local + team {
      guard out.count < itemsCap else { break }
      guard seen.insert(item.ref).inserted else { continue }
      out.append(item)
    }
    return out
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
