//
//  SearchResultsComposer.swift
//  UC-1 in-app search — pure composition from QueryEngine responses to
//  display rows for the Search screen. The screen answers the landing
//  promise "find the thread that explains why": decisions rank first,
//  detector hits (open questions / blockers) follow, raw FTS event matches
//  close the list. The SwiftUI body is a thin shell over these rows.
//

import Foundation

/// Track B1 — one labeled detail line of a result card (the landing mockup's
/// AUTHOR / CHANNEL / COMMIT / OUTCOME grid).
public struct SearchResultDetailRow: Equatable, Sendable, Identifiable {
  public enum Label: String, Sendable, CaseIterable {
    case author = "AUTHOR"
    case channel = "CHANNEL"
    case commit = "COMMIT"
    case outcome = "OUTCOME"
    case ticket = "TICKET"
    case pr = "PR"
    case thread = "THREAD"
  }

  public let label: Label
  public let value: String
  public let url: URL?

  public var id: String { "\(label.rawValue):\(value)" }

  public init(label: Label, value: String, url: URL? = nil) {
    self.label = label
    self.value = value
    self.url = url
  }
}

/// Track B1 — composed result set: rows + count copy + MATCH attribution.
public struct SearchResultsPresentation: Equatable, Sendable {
  public let rows: [SearchResultRow]
  public let totalCount: Int
  /// "1 result" / "N results" — the input-field counter of the mockup.
  public let countLabel: String
  /// Row carrying the MATCH badge (top-ranked result), nil when empty.
  public let topMatchID: String?

  public init(rows: [SearchResultRow]) {
    self.rows = rows
    self.totalCount = rows.count
    self.countLabel = rows.count == 1 ? "1 result" : "\(rows.count) results"
    self.topMatchID = rows.first?.id
  }
}

public struct SearchResultRow: Equatable, Sendable, Identifiable {
  public enum Kind: String, Sendable {
    case decision
    case openQuestion
    case blocker
    case event
  }

  public let id: String
  public let kind: Kind
  /// Headline — "GUN-12 · Fix relay reconnect" for events with a structured
  /// target; decision quote / question excerpt for detector rows.
  public let title: String
  /// Secondary body excerpt (event rows) — first line(s) of the matched
  /// text, view clamps to two lines.
  public let excerpt: String?
  /// "GitHub" / "Linear" / "Slack" / "AI" / "Local" — for event rows;
  /// kind-based label for detector rows.
  public let sourceLabel: String
  public let tsMs: Int64
  /// Outbound links of the originating event (decision rows) — the
  /// AUTHOR / COMMIT / OUTCOME composition material.
  public let links: [LinkView]
  public let confidence: Double?
  /// Collapsed duplicates behind this row (capture-side re-emission of the
  /// same target). 1 = unique.
  public let occurrenceCount: Int
  /// Track B1 — labeled detail grid (decision rows: AUTHOR / CHANNEL /
  /// COMMIT / TICKET / PR). Empty for rows without composition material.
  public let detailRows: [SearchResultDetailRow]

  public init(
    id: String, kind: Kind, title: String, excerpt: String? = nil,
    sourceLabel: String, tsMs: Int64, links: [LinkView] = [],
    confidence: Double? = nil, occurrenceCount: Int = 1,
    detailRows: [SearchResultDetailRow] = []
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.excerpt = excerpt
    self.sourceLabel = sourceLabel
    self.tsMs = tsMs
    self.links = links
    self.confidence = confidence
    self.occurrenceCount = occurrenceCount
    self.detailRows = detailRows
  }
}

public enum SearchResultsComposer {

  /// Track B1 — full presentation: composed rows + count copy + MATCH id.
  public static func composePresentation(
    from response: QueryActivityResponse
  ) -> SearchResultsPresentation {
    SearchResultsPresentation(rows: compose(from: response))
  }

  /// Group order: decisions (confidence desc, then recency) → open questions →
  /// blockers → events (newest first). Links are attached to decision rows by
  /// `fromEventID == decision.eventID`.
  public static func compose(from response: QueryActivityResponse) -> [SearchResultRow] {
    var rows: [SearchResultRow] = []

    let decisions = response.decisionsInPeriod.sorted {
      if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
      return $0.detectedAtMs > $1.detectedAtMs
    }
    for d in decisions {
      let links = response.links.filter { $0.fromEventID == d.eventID }
      let origin = response.events.first { $0.eventID == d.eventID }
      rows.append(
        SearchResultRow(
          id: "decision:\(d.id)",
          kind: .decision,
          title: d.reasoningExcerpt,
          sourceLabel: "Decision",
          tsMs: d.detectedAtMs,
          links: links,
          confidence: d.confidence,
          detailRows: detailRows(originatingEvent: origin, links: links)
        ))
    }

    for q in response.openQuestions.sorted(by: { $0.openedAtMs > $1.openedAtMs }) {
      rows.append(
        SearchResultRow(
          id: "question:\(q.id)",
          kind: .openQuestion,
          title: q.questionExcerpt,
          sourceLabel: "Open question",
          tsMs: q.openedAtMs
        ))
    }

    for b in response.blockers.sorted(by: { $0.startedAtMs > $1.startedAtMs }) {
      rows.append(
        SearchResultRow(
          id: "blocker:\(b.id)",
          kind: .blocker,
          title: b.blockerExcerpt ?? b.targetRef,
          sourceLabel: "Blocker",
          tsMs: b.startedAtMs
        ))
    }

    // Events — dedup first: capture-side re-emission can leave dozens of
    // identical rows for one target (same issue body per poll tick). Collapse
    // by (eventKind, target-or-text) keeping the newest, count the rest.
    var seen: [String: Int] = [:]  // dedup key → index in eventRows
    var eventRows: [SearchResultRow] = []
    let substanceEvents = response.events.filter {
      // Track B1 — pulse/diagnostic kinds never render as search results.
      EventKindTaxonomy.feedClass(eventKind: $0.eventKind, signalType: $0.signalType) == .substance
    }
    for e in substanceEvents.sorted(by: { $0.tsMs > $1.tsMs }) {
      let headline = composeEventHeadline(e)
      let dedupKey = "\(e.eventKind ?? "")|\(e.targetRef ?? headline)"
      if let idx = seen[dedupKey] {
        let kept = eventRows[idx]
        eventRows[idx] = SearchResultRow(
          id: kept.id, kind: kept.kind, title: kept.title, excerpt: kept.excerpt,
          sourceLabel: kept.sourceLabel, tsMs: kept.tsMs, links: kept.links,
          confidence: kept.confidence, occurrenceCount: kept.occurrenceCount + 1
        )
        continue
      }
      seen[dedupKey] = eventRows.count
      eventRows.append(
        SearchResultRow(
          id: "event:\(e.eventID)",
          kind: .event,
          title: headline,
          excerpt: composeEventExcerpt(e, headline: headline),
          sourceLabel: sourceLabel(eventKind: e.eventKind),
          tsMs: e.tsMs
        ))
    }
    rows.append(contentsOf: eventRows)

    return rows
  }

  /// "GUN-12 · Fix relay reconnect" when the payload carries a structured
  /// target; first line of the body otherwise; event_kind as the last resort.
  static func composeEventHeadline(_ e: ActivityEvent) -> String {
    var parts: [String] = []
    if let ref = e.targetRef, !ref.isEmpty { parts.append(ref) }
    if let title = e.targetTitle, !title.isEmpty { parts.append(title) }
    if !parts.isEmpty { return parts.joined(separator: " · ") }
    if let body = e.bodyExcerpt, !body.isEmpty {
      let firstLine = body.split(separator: "\n", maxSplits: 1)[0]
      return String(firstLine.prefix(120))
    }
    return e.eventKind ?? "event"
  }

  /// Body excerpt for the secondary line — only when the headline didn't
  /// already consume it (structured-target rows show body context below).
  static func composeEventExcerpt(_ e: ActivityEvent, headline: String) -> String? {
    guard let body = e.bodyExcerpt, !body.isEmpty else { return nil }
    let flattened = body.replacingOccurrences(of: "\n\n", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
    guard !headline.hasPrefix(String(flattened.prefix(40))) else { return nil }
    return String(flattened.prefix(200))
  }

  /// Track B1 — labeled detail grid for a decision row. Built from the link
  /// graph + the originating event's projection. Every line is optional —
  /// the card renders whatever composition material actually exists (no
  /// fabricated OUTCOME: it appears only when the data can carry it later).
  static func detailRows(
    originatingEvent origin: ActivityEvent?,
    links: [LinkView]
  ) -> [SearchResultDetailRow] {
    var rows: [SearchResultDetailRow] = []

    // AUTHOR — reviewer/user attributions from the link graph.
    if let author = links.first(where: { $0.targetKind == Schema.TargetKinds.githubUser }) {
      rows.append(SearchResultDetailRow(
        label: .author, value: author.targetRef,
        url: URL(string: "https://github.com/\(author.targetRef)")))
    }

    // CHANNEL — Slack origin.
    if let channel = origin?.channelName, !channel.isEmpty {
      rows.append(SearchResultDetailRow(label: .channel, value: "#\(channel)"))
    }

    // COMMIT — commit-flavored origin: subject (+ repo handle).
    if let origin, origin.eventKind == "git_commit_authored"
        || origin.eventKind == GitHubEventKindKey.commitPushed.rawValue,
       let body = origin.bodyExcerpt, !body.isEmpty {
      let subject = String(body.split(separator: "\n", maxSplits: 1)[0].prefix(80))
      let value = origin.targetRef.map { "\(subject) · \($0)" } ?? subject
      rows.append(SearchResultDetailRow(label: .commit, value: value))
    }

    // TICKET / PR — outbound refs from the link graph.
    if let ticket = links.first(where: { $0.targetKind == Schema.TargetKinds.linearIssue }) {
      rows.append(SearchResultDetailRow(label: .ticket, value: ticket.targetRef))
    }
    if let pr = links.first(where: { $0.targetKind == Schema.TargetKinds.githubPR }) {
      rows.append(SearchResultDetailRow(
        label: .pr, value: pr.targetRef, url: prURL(fromRef: pr.targetRef)))
    }
    return rows
  }

  /// "owner/repo#142" → canonical PR URL; other shapes → nil.
  static func prURL(fromRef ref: String) -> URL? {
    let parts = ref.split(separator: "#")
    guard parts.count == 2, parts[0].contains("/"), Int(parts[1]) != nil else { return nil }
    return URL(string: "https://github.com/\(parts[0])/pull/\(parts[1])")
  }

  /// Human source label from the event_kind prefix. `issue_updated` is the
  /// one legacy Linear kind without a `linear_` prefix.
  public static func sourceLabel(eventKind: String?) -> String {
    guard let kind = eventKind else { return "Local" }
    if kind.hasPrefix("gh_") { return "GitHub" }
    if kind.hasPrefix("linear_") || kind == "issue_updated" { return "Linear" }
    if kind.hasPrefix("slack_") { return "Slack" }
    if kind.hasPrefix("claude_") || kind.hasPrefix("ai_") { return "AI" }
    return "Local"
  }
}
