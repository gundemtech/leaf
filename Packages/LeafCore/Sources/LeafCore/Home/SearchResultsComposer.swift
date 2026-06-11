//
//  SearchResultsComposer.swift
//  UC-1 in-app search — pure composition from QueryEngine responses to
//  display rows for the Search screen. The screen answers the landing
//  promise "find the thread that explains why": decisions rank first,
//  detector hits (open questions / blockers) follow, raw FTS event matches
//  close the list. The SwiftUI body is a thin shell over these rows.
//

import Foundation

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

  public init(
    id: String, kind: Kind, title: String, excerpt: String? = nil,
    sourceLabel: String, tsMs: Int64, links: [LinkView] = [],
    confidence: Double? = nil, occurrenceCount: Int = 1
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
  }
}

public enum SearchResultsComposer {

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
      rows.append(
        SearchResultRow(
          id: "decision:\(d.id)",
          kind: .decision,
          title: d.reasoningExcerpt,
          sourceLabel: "Decision",
          tsMs: d.detectedAtMs,
          links: response.links.filter { $0.fromEventID == d.eventID },
          confidence: d.confidence
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
    for e in response.events.sorted(by: { $0.tsMs > $1.tsMs }) {
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
