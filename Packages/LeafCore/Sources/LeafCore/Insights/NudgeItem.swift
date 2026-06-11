//
//  NudgeItem.swift
//  UC-2 nudges — "am I quietly stuck?" rows. Derived locally, surfaced only
//  on this Mac (Home card + menubar), never shared to the team: the landing
//  promise is explicit — visible only to you, no manager dashboard.
//
//  Kinds map the marketing card one-to-one:
//    stalledPR       — your open PR with no movement for N days
//    stalledTicket   — Linear issue sitting in the same started-state too long
//    openBlocker     — detector-found blocker still unresolved
//    highSwitchRate  — unusually fragmented attention today
//
//  Production SQL + exact thresholds live in the moat
//  (`ProdInsights+Nudges`); this file is the public value type only.
//

import Foundation

public struct NudgeItem: Equatable, Hashable, Sendable, Identifiable {
  public enum Kind: String, Equatable, Hashable, Sendable {
    case stalledPR
    case stalledTicket
    case openBlocker
    case highSwitchRate
  }

  public let id: String
  public let kind: Kind
  /// "Stalled PR for 3 days"
  public let title: String
  /// "leaf#142 · Add relay proxy"
  public let detail: String?
  public let sourceURL: URL?
  /// When the stuck condition started (ms epoch) — drives "for N days" copy
  /// and recency sort.
  public let sinceMs: Int64

  public init(
    id: String, kind: Kind, title: String, detail: String?,
    sourceURL: URL?, sinceMs: Int64
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.detail = detail
    self.sourceURL = sourceURL
    self.sinceMs = sinceMs
  }
}
