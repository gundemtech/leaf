//
//  NowHeroComposer.swift
//  Home redesign — the NOW hero is the single top-of-Home card that merges the
//  former RESUME hero and YOU'RE ON blocks (both degraded into the same
//  "branch · +N ahead" line whenever whereStopped/linearID were absent).
//  Pure-function composition for testability; the SwiftUI body in
//  `Leaf/Views/Window/Home/Blocks/NowHeroBlock.swift` is a thin shell.
//

import Foundation

/// Display-ready lines for the NOW hero card. Any line may be nil; `isEmpty`
/// routes the card to its empty state.
public struct NowHeroPresentation: Equatable, Sendable {
  /// "GUN-56 · feature/relay · leaf" — linearID / branch / repo, nil-skipped.
  public let taskLine: String?
  /// "Started 09:18 · 1h 32m focused so far" (YoureOnRowComposer pass-through).
  public let sessionLine: String?
  /// "HomeView.swift:42" — where-stopped anchor, falls back to the excerpt.
  public let anchorLine: String?
  /// "Last commit: “fix relay reconnect”" — capped at 60 chars.
  public let commitLine: String?
  /// "2 uncommitted · 4 ahead of main" — ahead/behind suppressed on trunk.
  public let wipLine: String?
  /// "Open files: A.swift · B.swift".
  public let filesLine: String?

  public var isEmpty: Bool {
    taskLine == nil && sessionLine == nil && anchorLine == nil
      && commitLine == nil && wipLine == nil && filesLine == nil
  }
}

public enum NowHeroComposer {

  /// Branch names that denote a shared trunk — "commits ahead of main" on a
  /// trunk is structural repo topology (e.g. dev vs release-only main), not
  /// the user's WIP, so ahead/behind is suppressed for these.
  static let trunkBranchNames: Set<String> = ["main", "master", "dev", "develop", "trunk"]

  public static func compose(
    taskIdentity: TaskIdentity?,
    gitDelta: GitDeltaSnapshot?,
    session: CurrentTaskSession?,
    whereStopped: WhereStoppedSnapshot?,
    lastCommit: RecentCommitSnapshot? = nil,
    now: Date,
    calendar: Calendar
  ) -> NowHeroPresentation {
    NowHeroPresentation(
      taskLine: composeTaskLine(taskIdentity, delta: gitDelta),
      sessionLine: session.flatMap { composeSessionLine($0, now: now, calendar: calendar) },
      anchorLine: composeAnchorLine(whereStopped),
      // Where-stopped's anchored commit wins; the freestanding recent-commit
      // read covers the (current) reality where whereStopped is stubbed nil.
      commitLine: (whereStopped?.recentLastCommit ?? lastCommit).map(composeCommitLine),
      wipLine: composeWipLine(branch: taskIdentity?.branch, delta: gitDelta),
      filesLine: YoureOnRowComposer.composeFilesLine(session?.openFiles ?? [])
    )
  }

  /// Session line with a fallback guard: when the substrate resolved no real
  /// IDE/AI session (`sessionSource == .fallback`), the start time is a
  /// synthetic today-00:00 — showing "Started 00:00" reads as a fact and is
  /// noise. Suppress the start clause; keep real focused minutes if any.
  static func composeSessionLine(
    _ session: CurrentTaskSession, now: Date, calendar: Calendar
  ) -> String? {
    guard session.sessionSource == .fallback else {
      return YoureOnRowComposer.composeSessionLine(
        sessionStartMs: session.sessionStartMs, focusedMin: session.focusedMinSoFar,
        now: now, calendar: calendar)
    }
    guard session.focusedMinSoFar > 0 else { return nil }
    return "\(YoureOnRowComposer.formatFocusedMin(session.focusedMinSoFar)) focused so far"
  }

  /// "GUN-56 · feature/relay · gundemtech/leaf". Repo falls back to the git
  /// remote (owner/name) when the task identity didn't resolve one; dropped
  /// when it duplicates the branch text (degenerate single-segment checkouts).
  static func composeTaskLine(
    _ identity: TaskIdentity?, delta: GitDeltaSnapshot? = nil
  ) -> String? {
    var parts: [String] = []
    if let linearID = identity?.linearID, !linearID.isEmpty { parts.append(linearID) }
    if let branch = identity?.branch, !branch.isEmpty { parts.append(branch) }
    let repo = identity?.repo.flatMap { $0.isEmpty ? nil : $0 }
      ?? delta?.remote.map { "\($0.owner)/\($0.repo)" }
    if let repo, !parts.contains(repo) { parts.append(repo) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// Uncommitted count always surfaces; ahead/behind only on a KNOWN
  /// non-trunk branch (and only when the branch isn't itself the merge-base
  /// ref). Unknown branch fails quiet — a trunk checkout with an unresolved
  /// branch must not regress into the "+87 ahead of main" structural noise
  /// this rule exists to suppress.
  static func composeWipLine(branch: String?, delta: GitDeltaSnapshot?) -> String? {
    guard let delta else { return nil }
    var clauses: [String] = []
    if delta.uncommittedCount > 0 {
      clauses.append("\(delta.uncommittedCount) uncommitted")
    }
    let baseRef = delta.mergeBase.map(YoureOnRowComposer.refBasename)
    if let baseRef, let branch, !branch.isEmpty,
      !isTrunk(branch: branch, mergeBaseBasename: baseRef)
    {
      if delta.commitsAhead > 0 { clauses.append("\(delta.commitsAhead) ahead of \(baseRef)") }
      if delta.commitsBehind > 0 { clauses.append("\(delta.commitsBehind) behind \(baseRef)") }
    }
    return clauses.isEmpty ? nil : clauses.joined(separator: " · ")
  }

  /// Case-insensitive on both arms — git refs are case-sensitive in
  /// principle, but macOS checkouts live on a case-insensitive FS.
  public static func isTrunk(branch: String?, mergeBaseBasename: String) -> Bool {
    guard let branch, !branch.isEmpty else { return false }
    return trunkBranchNames.contains(branch.lowercased())
      || branch.lowercased() == mergeBaseBasename.lowercased()
  }

  static func composeAnchorLine(_ snap: WhereStoppedSnapshot?) -> String? {
    guard let snap else { return nil }
    if let basename = snap.anchorFilePath, !basename.isEmpty {
      if let line = snap.anchorLine, line > 0 { return "\(basename):\(line)" }
      return basename
    }
    return snap.excerpt.isEmpty ? nil : snap.excerpt
  }

  static func composeCommitLine(_ commit: RecentCommitSnapshot) -> String {
    let trimmed = commit.subject.trimmingCharacters(in: .whitespaces)
    let capped = trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
    return "Last commit: “\(capped)”"
  }
}
