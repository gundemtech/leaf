//
//  WorkspaceHubPresentation.swift
//  Team → Workspace Hub — pure presentation logic for the hub page
//  (header subtitle, roster ordering, viewer-admin detection) plus the
//  TeamHubTab enum shared by the view layer and WindowState deep-links.
//  Lives in LeafCore so it is testable without the app target (the app
//  target has no test bundle — TeamFeedPresentation precedent).
//

import Foundation

/// Tabs of the Team workspace-hub page. Raw values are a persistence /
/// deep-link contract: unknown raw strings must decode to nil so callers
/// can fall back to `.feed`.
public enum TeamHubTab: String, CaseIterable, Identifiable, Hashable, Sendable {
  case feed
  case members
  case settings

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .feed: "Feed"
    case .members: "Members"
    case .settings: "Settings"
    }
  }
}

public enum WorkspaceHubPresentation {

  /// Header subtitle: "3 members · created Apr 24, 2026". Absolute date —
  /// the header states workspace identity, not activity (relative "joined
  /// X ago" stays in member rows). Locale/timeZone params keep tests
  /// deterministic; production callers use the defaults.
  public static func subtitle(
    memberCount: Int,
    createdAt: Date,
    locale: Locale = .current,
    timeZone: TimeZone = .current
  ) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    let noun = memberCount == 1 ? "member" : "members"
    return "\(memberCount) \(noun) · created \(formatter.string(from: createdAt))"
  }

  /// Roster ordering for the Members tab: admins first, then
  /// case-insensitive alphabetical by display name, stable tiebreak by id.
  public static func sortedRoster(_ members: [TeamMember]) -> [TeamMember] {
    members.sorted { a, b in
      if (a.role == .admin) != (b.role == .admin) {
        return a.role == .admin
      }
      let name = a.displayName.localizedCaseInsensitiveCompare(b.displayName)
      if name != .orderedSame {
        return name == .orderedAscending
      }
      return a.id < b.id
    }
  }

  /// True when the viewer (by identity pubkey) is an admin of the roster.
  /// Extraction of the check previously duplicated across
  /// WorkspaceSettingsSection / WorkspaceMembersAdminList. Empty hex never
  /// matches (uninitialized identity must not look like an admin).
  public static func isViewerAdmin(pubkeyHex: String, members: [TeamMember]) -> Bool {
    guard !pubkeyHex.isEmpty else { return false }
    return members.contains { $0.pubkeyHex == pubkeyHex && $0.role == .admin }
  }
}
