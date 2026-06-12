//
//  HandoffContextSnapshot.swift
//  Use-case rebuild Track C (UC-4) — structured context riding inside a
//  handoff DM: last commit / open review / ticket status / last thread, the
//  landing-page handoff card. ADR-010 by construction: refs, subjects,
//  counts and state names only — never bodies.
//
//  Versioning contract (the load-bearing part):
//    • Old client, new message: JSONDecoder ignores unknown plaintext keys —
//      the snapshot is invisible, the handoff renders as plain text.
//    • New client, corrupt/future snapshot: every layer decodes via
//      `try? decodeIfPresent`, degrading to nil — a malformed snapshot can
//      NEVER fail the whole `DirectMessagePlaintext` (the cross_post
//      jsonb-decode incident is the anti-pattern: one bad row killed whole
//      inbound batches).
//

import Foundation

public struct HandoffContextSnapshot: Sendable, Equatable, Codable, Hashable {
  public static let currentSchemaVersion = 1

  public struct CommitLine: Sendable, Equatable, Codable, Hashable {
    public let sha: String?
    public let subject: String?
    public let branch: String?
    public let repo: String?
    public let tsMs: Int64?

    public init(sha: String?, subject: String?, branch: String?, repo: String?, tsMs: Int64?) {
      self.sha = sha
      self.subject = subject
      self.branch = branch
      self.repo = repo
      self.tsMs = tsMs
    }

    private enum CodingKeys: String, CodingKey {
      case sha, subject, branch, repo
      case tsMs = "ts_ms"
    }
  }

  public struct ReviewLine: Sendable, Equatable, Codable, Hashable {
    /// "owner/repo#142"
    public let ref: String?
    public let commentCount: Int?
    public let url: String?

    public init(ref: String?, commentCount: Int?, url: String?) {
      self.ref = ref
      self.commentCount = commentCount
      self.url = url
    }

    private enum CodingKeys: String, CodingKey {
      case ref, url
      case commentCount = "comment_count"
    }
  }

  public struct TicketLine: Sendable, Equatable, Codable, Hashable {
    public let ref: String?
    public let state: String?
    public let cycle: String?

    public init(ref: String?, state: String?, cycle: String?) {
      self.ref = ref
      self.state = state
      self.cycle = cycle
    }
  }

  public struct ThreadLine: Sendable, Equatable, Codable, Hashable {
    public let channel: String?
    public let messageCount: Int?

    public init(channel: String?, messageCount: Int?) {
      self.channel = channel
      self.messageCount = messageCount
    }

    private enum CodingKeys: String, CodingKey {
      case channel
      case messageCount = "message_count"
    }
  }

  public let schemaVersion: Int
  /// Short topic for the card header ("handoff · auth refactor").
  public let title: String?
  public let lastCommit: CommitLine?
  public let openReview: ReviewLine?
  public let ticket: TicketLine?
  public let lastThread: ThreadLine?
  public let capturedAtMs: Int64

  /// Card renders only when at least one line carries data.
  public var hasAnyLine: Bool {
    lastCommit != nil || openReview != nil || ticket != nil || lastThread != nil
  }

  public init(
    schemaVersion: Int = HandoffContextSnapshot.currentSchemaVersion,
    title: String?,
    lastCommit: CommitLine?,
    openReview: ReviewLine?,
    ticket: TicketLine?,
    lastThread: ThreadLine?,
    capturedAtMs: Int64
  ) {
    self.schemaVersion = schemaVersion
    self.title = title
    self.lastCommit = lastCommit
    self.openReview = openReview
    self.ticket = ticket
    self.lastThread = lastThread
    self.capturedAtMs = capturedAtMs
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case title
    case lastCommit = "last_commit"
    case openReview = "open_review"
    case ticket
    case lastThread = "last_thread"
    case capturedAtMs = "captured_at_ms"
  }

  /// Forward-tolerant decode: a v2 snapshot with extra fields still renders
  /// its known lines; a malformed sub-object degrades to nil instead of
  /// throwing out of the plaintext decode.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.schemaVersion =
      (try? container.decodeIfPresent(Int.self, forKey: .schemaVersion))
      ?? Self.currentSchemaVersion
    self.title = try? container.decodeIfPresent(String.self, forKey: .title)
    self.lastCommit = try? container.decodeIfPresent(CommitLine.self, forKey: .lastCommit)
    self.openReview = try? container.decodeIfPresent(ReviewLine.self, forKey: .openReview)
    self.ticket = try? container.decodeIfPresent(TicketLine.self, forKey: .ticket)
    self.lastThread = try? container.decodeIfPresent(ThreadLine.self, forKey: .lastThread)
    self.capturedAtMs = (try? container.decodeIfPresent(Int64.self, forKey: .capturedAtMs)) ?? 0
  }
}

/// Sender side — pure projection of `CurrentWorkResponse` into the snapshot.
/// Consumes the B0 work-aware fields; every line nil-degrades.
public enum HandoffSnapshotBuilder {
  public static func build(
    from work: CurrentWorkResponse,
    title: String?,
    nowMs: Int64
  ) -> HandoffContextSnapshot {
    let commit: HandoffContextSnapshot.CommitLine? = work.lastCommit.map {
      .init(sha: $0.sha, subject: $0.subject ?? $0.message.map(firstLine),
            branch: $0.branch, repo: $0.repoFullName, tsMs: $0.pushedAtMs)
    }
    let review: HandoffContextSnapshot.ReviewLine? = work.openPR.map {
      .init(ref: $0.ref, commentCount: $0.commentCount, url: $0.url)
    }
    let ticket: HandoffContextSnapshot.TicketLine? = work.inProgressLinearTicket.map {
      .init(ref: $0.issueRef, state: $0.stateName, cycle: nil)
    }
    let thread: HandoffContextSnapshot.ThreadLine? = work.lastThread.map {
      .init(channel: $0.channelName, messageCount: $0.messageCount)
    }
    return HandoffContextSnapshot(
      title: title?.isEmpty == true ? nil : title,
      lastCommit: commit,
      openReview: review,
      ticket: ticket,
      lastThread: thread,
      capturedAtMs: nowMs
    )
  }

  private static func firstLine(_ s: String) -> String {
    String(s.split(separator: "\n", maxSplits: 1)[0])
  }
}

/// Recipient side — pure formatting into the landing card's four labeled rows.
public enum HandoffCardPresentation {
  public struct Row: Equatable, Sendable, Identifiable {
    public let label: String
    public let value: String
    /// Leading accent segment ("feat:", "#142") for the green highlight.
    public let accentPrefix: String?
    public let url: URL?

    public var id: String { label }

    public init(label: String, value: String, accentPrefix: String? = nil, url: URL? = nil) {
      self.label = label
      self.value = value
      self.accentPrefix = accentPrefix
      self.url = url
    }
  }

  /// "handoff · auth refactor" (header of the card).
  public static func headerTitle(from snapshot: HandoffContextSnapshot) -> String {
    snapshot.title.map { "handoff · \($0)" } ?? "handoff"
  }

  public static func rows(
    from snapshot: HandoffContextSnapshot, nowMs: Int64
  ) -> [Row] {
    var rows: [Row] = []

    if let commit = snapshot.lastCommit, let subject = commit.subject ?? commit.sha {
      var value = subject
      if let ts = commit.tsMs, ts > 0 {
        value += " · \(relative(ts, nowMs: nowMs))"
      }
      let accent = subject.firstIndex(of: ":").map {
        String(subject[subject.startIndex...$0])
      }
      rows.append(Row(label: "LAST COMMIT", value: value, accentPrefix: accent))
    }
    if let review = snapshot.openReview, let ref = review.ref {
      let shortRef = ref.split(separator: "#").last.map { "#\($0)" } ?? ref
      var value = shortRef
      if let comments = review.commentCount {
        value += " · \(comments) comment\(comments == 1 ? "" : "s")"
      }
      rows.append(Row(
        label: "OPEN REVIEW", value: value, accentPrefix: shortRef,
        url: review.url.flatMap(URL.init(string:))))
    }
    if let ticket = snapshot.ticket, let state = ticket.state ?? ticket.ref {
      var value = state
      if ticket.state != nil, let cycle = ticket.cycle {
        value += " · \(cycle)"
      } else if ticket.state != nil, let ref = ticket.ref {
        value += " · \(ref)"
      }
      rows.append(Row(label: "STATUS", value: value))
    }
    if let thread = snapshot.lastThread, let channel = thread.channel {
      var value = "#\(channel)"
      if let count = thread.messageCount {
        value += " · \(count) msg\(count == 1 ? "" : "s")"
      }
      rows.append(Row(label: "LAST THREAD", value: value, accentPrefix: "#\(channel)"))
    }
    return rows
  }

  static func relative(_ tsMs: Int64, nowMs: Int64) -> String {
    let deltaSec = max(0, nowMs - tsMs) / 1000
    switch deltaSec {
    case ..<3600: return "\(max(1, deltaSec / 60))m ago"
    case ..<86_400: return "\(deltaSec / 3600)h ago"
    default: return "\(deltaSec / 86_400)d ago"
    }
  }
}
