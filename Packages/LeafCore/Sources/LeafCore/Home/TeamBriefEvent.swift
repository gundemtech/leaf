//
//  TeamBriefEvent.swift
//  Use-case rebuild Track B3 — slim projection of a teammate's mirrored event
//  for brief aggregation ("what did the TEAM ship"). Mapped from
//  `team_events_mirror` plaintext payloads (already ADR-010-allowlisted by
//  the sender's TeamEventPayloadBuilder).
//

import Foundation

public struct TeamBriefEvent: Equatable, Sendable {
  /// Raw mirrored event kind ("gh_pr_merged" / "status_transition").
  public let kind: String
  public let senderPubkeyHex: String
  /// "owner/repo" when the payload carries one.
  public let repoHint: String?
  /// "owner/repo#142" / "LEA-431".
  public let ref: String?
  public let title: String?
  public let tsMs: Int64

  public init(
    kind: String, senderPubkeyHex: String, repoHint: String?,
    ref: String?, title: String?, tsMs: Int64
  ) {
    self.kind = kind
    self.senderPubkeyHex = senderPubkeyHex
    self.repoHint = repoHint
    self.ref = ref
    self.title = title
    self.tsMs = tsMs
  }

  /// Brief-relevant projection: merged PRs and completed status transitions.
  /// Everything else → nil (the brief counts shipped outcomes, not activity).
  public static func from(_ row: TeamEventMirrorRow) -> TeamBriefEvent? {
    guard let data = row.plaintextPayloadJSON.data(using: .utf8),
          let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }

    func str(_ key: String) -> String? {
      (dict[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    switch row.kind {
    case "gh_pr_merged":
      let repo = str("repo_full_name")
      let number = str("pr_number") ?? (dict["pr_number"] as? Int).map(String.init)
      return TeamBriefEvent(
        kind: row.kind,
        senderPubkeyHex: row.senderPubkeyHex,
        repoHint: repo,
        ref: repo.flatMap { r in number.map { "\(r)#\($0)" } },
        title: str("pr_title_excerpt"),
        tsMs: row.eventTsMs
      )
    case "status_transition", "linear_status_transition":
      guard str("issue_state_type") == "completed" else { return nil }
      return TeamBriefEvent(
        kind: row.kind,
        senderPubkeyHex: row.senderPubkeyHex,
        repoHint: nil,
        ref: str("issue_identifier"),
        title: str("issue_title_excerpt"),
        tsMs: row.eventTsMs
      )
    default:
      return nil
    }
  }
}
