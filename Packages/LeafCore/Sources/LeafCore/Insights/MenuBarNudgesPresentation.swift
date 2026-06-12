//
//  MenuBarNudgesPresentation.swift
//  Use-case rebuild Track B4 — the "menu bar · you" panel of the landing
//  mockup: compact nudges section for the menubar popover. Pure composition;
//  the popover view renders the model.
//

import Foundation

public enum MenuBarNudgesPresentation {

  public struct Model: Equatable, Sendable {
    /// "you · last 24h"
    public let headerLabel: String
    /// "3 NUDGES"
    public let countLabel: String
    /// Oldest-stuck first (the longest-ignored pain leads), capped.
    public let rows: [NudgeItem]
    /// The landing privacy contract, verbatim.
    public let footer: String

    public init(headerLabel: String, countLabel: String, rows: [NudgeItem], footer: String) {
      self.headerLabel = headerLabel
      self.countLabel = countLabel
      self.rows = rows
      self.footer = footer
    }
  }

  public static let defaultCap = 3

  /// nil when there is nothing to nudge about — the popover hides the section
  /// entirely (no empty-state noise in a glanceable surface).
  public static func compose(nudges: [NudgeItem], cap: Int = defaultCap) -> Model? {
    guard !nudges.isEmpty else { return nil }
    let sorted = nudges.sorted { $0.sinceMs < $1.sinceMs }
    return Model(
      headerLabel: "you · last 24h",
      countLabel: "\(nudges.count) NUDGE\(nudges.count == 1 ? "" : "S")",
      rows: Array(sorted.prefix(max(1, cap))),
      footer: "visible only to you · no manager dashboard"
    )
  }
}
