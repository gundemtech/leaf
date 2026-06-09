//
//  TeamFeedPresentation.swift
//  LeafCore
//
//  Team UI polish — pure presentation transforms for the Team feed.
//  Deterministic given (items, now, calendar); consumed by TeamView
//  (Leaf app target). Lives here so the logic is testable — the app
//  target has no test bundle by convention.
//

import Foundation

// MARK: - TeamMemberNameResolver

/// Resolves a feed actor's display name. Raw pubkey hex must never reach the UI.
public enum TeamMemberNameResolver {

  /// Order: live workspace member → embedded display name (e.g. carried on the
  /// DM row at send time) → "Former teammate".
  public static func displayName(
    pubkeyHex: String,
    members: [TeamMember],
    embeddedDisplayName: String? = nil
  ) -> String {
    if let m = members.first(where: { $0.pubkeyHex == pubkeyHex }) {
      return m.displayName
    }
    if let embedded = embeddedDisplayName, !embedded.isEmpty {
      return embedded
    }
    return "Former teammate"
  }
}

// MARK: - FeedTimestampStyle

/// Which timestamp string a feed row should render.
public enum FeedTimestampStyle: Equatable, Sendable {
  /// Same calendar day as `now` → relative ("23m ago").
  case relative
  /// Older day → clock time ("14:32"); the date itself comes from the
  /// section separator, repeating it per-row is noise.
  case clock
}

// MARK: - FeedDaySection

/// One calendar day of feed items, newest-first within and across sections.
public struct FeedDaySection: Identifiable, Equatable, Sendable {
  /// "day-YYYY-MM-DD" — stable across refreshes for ForEach identity.
  public let id: String
  /// "Today" | "Yesterday" | "May 20" | "May 20, 2025".
  public let label: String
  public let items: [FeedItem]

  public init(id: String, label: String, items: [FeedItem]) {
    self.id = id
    self.label = label
    self.items = items
  }
}

// MARK: - DMRenderFlags

/// Per-DM render decisions derived from run (consecutive-series) grouping.
public struct DMRenderFlags: Equatable, Sendable {
  /// Show avatar + name + timestamp header (first/newest message of a run).
  public let showsHeader: Bool
  /// Show "Read Nm ago" under the bubble (newest READ outbound message of a run).
  public let showsReceipt: Bool

  public init(showsHeader: Bool, showsReceipt: Bool) {
    self.showsHeader = showsHeader
    self.showsReceipt = showsReceipt
  }
}

// MARK: - TeamFeedPresentation

public enum TeamFeedPresentation {

  /// Max gap between adjacent messages of one run (5 min).
  public static let runWindowMs: Int64 = 300_000

  public static func timestampStyle(
    forMs ms: Int64,
    now: Date,
    calendar: Calendar
  ) -> FeedTimestampStyle {
    let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    return calendar.isDate(date, inSameDayAs: now) ? .relative : .clock
  }

  /// Groups a newest-first feed into day sections. `.grouped` bursts use their
  /// `timestamp` (spanEnd) — a burst straddling midnight lands on its newest day.
  public static func daySections(
    items: [FeedItem],
    now: Date,
    calendar: Calendar
  ) -> [FeedDaySection] {
    var sections: [FeedDaySection] = []
    var currentKey: String? = nil
    var currentItems: [FeedItem] = []
    var currentLabel = ""

    func flush() {
      guard let key = currentKey else { return }
      sections.append(FeedDaySection(id: key, label: currentLabel, items: currentItems))
      currentItems = []
    }

    for item in items {
      let date = Date(timeIntervalSince1970: TimeInterval(item.timestamp) / 1000)
      let comps = calendar.dateComponents([.year, .month, .day], from: date)
      let key = String(
        format: "day-%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
      if key != currentKey {
        flush()
        currentKey = key
        currentLabel = dayLabel(for: date, now: now, calendar: calendar)
      }
      currentItems.append(item)
    }
    flush()
    return sections
  }

  private static func dayLabel(for date: Date, now: Date, calendar: Calendar) -> String {
    if calendar.isDate(date, inSameDayAs: now) { return "Today" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
      calendar.isDate(date, inSameDayAs: yesterday)
    {
      return "Yesterday"
    }
    let fmt = DateFormatter()
    fmt.calendar = calendar
    fmt.timeZone = calendar.timeZone
    fmt.locale = Locale(identifier: "en_US")
    let sameYear =
      calendar.component(.year, from: date) == calendar.component(.year, from: now)
    fmt.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
    return fmt.string(from: date)
  }

  /// Computes per-message render flags for one display-ordered (newest-first)
  /// slice of the feed — call PER DAY SECTION so runs never cross a date
  /// separator. Keyed by messageID; non-DM items break runs.
  ///
  /// Run key: direction + conversation peer — outbound keys on the recipient,
  /// inbound on the sender. The feed is multi-recipient: messages to/from
  /// different people must never merge into one visual series.
  public static func dmRenderFlags(items: [FeedItem]) -> [String: DMRenderFlags] {
    var flags: [String: DMRenderFlags] = [:]
    var runs: [[DirectMessageMirrorRow]] = []
    var current: [DirectMessageMirrorRow] = []

    func runKey(_ row: DirectMessageMirrorRow) -> String {
      switch row.direction {
      case .outbound: return "out-\(row.recipientPubkeyHex)"
      case .inbound: return "in-\(row.senderPubkeyHex)"
      }
    }
    func flush() {
      if !current.isEmpty { runs.append(current) }
      current = []
    }

    for item in items {
      guard case .directMessage(let row) = item else {
        flush()
        continue
      }
      if let prev = current.last,
        runKey(prev) == runKey(row),
        prev.serverCreatedAtMs - row.serverCreatedAtMs <= runWindowMs
      {
        current.append(row)
      } else {
        flush()
        current = [row]
      }
    }
    flush()

    for run in runs {
      // Newest read outbound message of the run carries the receipt.
      let receiptID = run.first(where: { $0.direction == .outbound && $0.readAtMs != nil })?
        .messageID
      for (idx, row) in run.enumerated() {
        flags[row.messageID] = DMRenderFlags(
          showsHeader: idx == 0,
          showsReceipt: row.messageID == receiptID
        )
      }
    }
    return flags
  }
}
