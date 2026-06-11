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
  /// Primary display text — decision quote / question excerpt / event body.
  public let title: String
  /// "GitHub" / "Linear" / "Slack" / "AI" / "Local" — for event rows;
  /// kind-based label for detector rows.
  public let sourceLabel: String
  public let tsMs: Int64
  /// Outbound links of the originating event (decision rows) — the
  /// AUTHOR / COMMIT / OUTCOME composition material.
  public let links: [LinkView]
  public let confidence: Double?

  public init(
    id: String, kind: Kind, title: String, sourceLabel: String,
    tsMs: Int64, links: [LinkView] = [], confidence: Double? = nil
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.sourceLabel = sourceLabel
    self.tsMs = tsMs
    self.links = links
    self.confidence = confidence
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

    for e in response.events.sorted(by: { $0.tsMs > $1.tsMs }) {
      let title = (e.bodyExcerpt?.isEmpty == false) ? e.bodyExcerpt! : (e.eventKind ?? "event")
      rows.append(
        SearchResultRow(
          id: "event:\(e.eventID)",
          kind: .event,
          title: title,
          sourceLabel: sourceLabel(eventKind: e.eventKind),
          tsMs: e.tsMs
        ))
    }

    return rows
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
