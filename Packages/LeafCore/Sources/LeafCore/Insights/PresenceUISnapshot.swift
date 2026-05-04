import Foundation
import GRDB

/// Phase 4.10.A — typed view-model over the raw `presence_state` rows
/// produced in Phase 4.7.B by `PresenceStateWriter`. Exists so SwiftUI can
/// drive a Live Presence widget without reaching into `[String: Any]` dicts
/// in view code.
///
/// Per provider, only the fields the dashboard renders are extracted; the
/// raw `state_json` keeps everything else available for MCP / future
/// surfaces. ADR-010: only counts, status enums, and self-authored cycle /
/// channel names — bodies, message text, and PII are never surfaced.
public struct PresenceUISnapshot: Sendable, Hashable {
    public struct GitHub: Sendable, Hashable {
        public let prsAwaitingMyReview: Int
        public let myOpenPRs: Int
        public let notificationsUnread: Int
        public let latestPushCheckStatus: String?
        public let updatedAtMs: Int64

        public init(
            prsAwaitingMyReview: Int,
            myOpenPRs: Int,
            notificationsUnread: Int,
            latestPushCheckStatus: String?,
            updatedAtMs: Int64
        ) {
            self.prsAwaitingMyReview = prsAwaitingMyReview
            self.myOpenPRs = myOpenPRs
            self.notificationsUnread = notificationsUnread
            self.latestPushCheckStatus = latestPushCheckStatus
            self.updatedAtMs = updatedAtMs
        }
    }

    public struct Linear: Sendable, Hashable {
        public let startedIssuesCount: Int
        public let topPriority: String
        public let cycleName: String?
        public let cycleCompletedPct: Int?
        public let cycleDaysRemaining: Int?
        public let updatedAtMs: Int64

        public init(
            startedIssuesCount: Int,
            topPriority: String,
            cycleName: String?,
            cycleCompletedPct: Int?,
            cycleDaysRemaining: Int?,
            updatedAtMs: Int64
        ) {
            self.startedIssuesCount = startedIssuesCount
            self.topPriority = topPriority
            self.cycleName = cycleName
            self.cycleCompletedPct = cycleCompletedPct
            self.cycleDaysRemaining = cycleDaysRemaining
            self.updatedAtMs = updatedAtMs
        }
    }

    public struct Slack: Sendable, Hashable {
        public let nativePresence: String
        public let dndActive: Bool
        public let inHuddle: Bool
        public let mentionsToday: Int
        public let filesToday: Int
        public let statusEmoji: String?
        public let updatedAtMs: Int64

        public init(
            nativePresence: String,
            dndActive: Bool,
            inHuddle: Bool,
            mentionsToday: Int,
            filesToday: Int,
            statusEmoji: String?,
            updatedAtMs: Int64
        ) {
            self.nativePresence = nativePresence
            self.dndActive = dndActive
            self.inHuddle = inHuddle
            self.mentionsToday = mentionsToday
            self.filesToday = filesToday
            self.statusEmoji = statusEmoji
            self.updatedAtMs = updatedAtMs
        }
    }

    public let github: GitHub?
    public let linear: Linear?
    public let slack: Slack?

    public init(github: GitHub? = nil, linear: Linear? = nil, slack: Slack? = nil) {
        self.github = github
        self.linear = linear
        self.slack = slack
    }

    public static let empty = PresenceUISnapshot()

    public var isEmpty: Bool { github == nil && linear == nil && slack == nil }

    /// Read all `presence_state` rows and map to typed UI snapshot.
    /// Missing rows ↔ optional fields stay nil. Malformed JSON fields default
    /// to safe zeros / "unknown" — never crashes the dashboard.
    public static func read(database: Database) throws -> PresenceUISnapshot {
        var github: GitHub?
        var linear: Linear?
        var slack: Slack?

        try database.readSQL { rawDB in
            let all = try PresenceStateWriter.readAll(in: rawDB)

            if let entry = all[.github] {
                github = GitHub(
                    prsAwaitingMyReview: intValue(entry.state["prs_awaiting_my_review"]),
                    myOpenPRs: intValue(entry.state["my_open_prs"]),
                    notificationsUnread: intValue(entry.state["notifications_unread"]),
                    latestPushCheckStatus: stringValue(entry.state["latest_push_check_status"]),
                    updatedAtMs: entry.updatedAtMs
                )
            }

            if let entry = all[.linear] {
                let cycle = entry.state["current_cycle"] as? [String: Any]
                let cycleName = cycle.flatMap { stringValue($0["cycle_name"]) }
                let pct = cycle.flatMap { ($0["completed_pct"] as? Int) ?? optionalIntValue($0["completed_pct"]) }
                let days = cycle.flatMap { ($0["days_remaining"] as? Int) ?? optionalIntValue($0["days_remaining"]) }
                linear = Linear(
                    startedIssuesCount: intValue(entry.state["started_issues_count"]),
                    topPriority: stringValue(entry.state["top_priority"]) ?? "none",
                    cycleName: cycleName,
                    cycleCompletedPct: pct,
                    cycleDaysRemaining: days,
                    updatedAtMs: entry.updatedAtMs
                )
            }

            if let entry = all[.slack] {
                let dnd = entry.state["dnd"] as? [String: Any]
                let dndActive = (dnd?["is_active"] as? Bool) ?? false
                slack = Slack(
                    nativePresence: stringValue(entry.state["native_presence"]) ?? "unknown",
                    dndActive: dndActive,
                    inHuddle: (entry.state["in_huddle"] as? Bool) ?? false,
                    mentionsToday: intValue(entry.state["mention_count_today"]),
                    filesToday: intValue(entry.state["file_count_today"]),
                    statusEmoji: stringValue(entry.state["status_emoji"]).flatMap { $0.isEmpty ? nil : $0 },
                    updatedAtMs: entry.updatedAtMs
                )
            }
        }

        return PresenceUISnapshot(github: github, linear: linear, slack: slack)
    }

    // MARK: - Helpers

    private static func intValue(_ raw: Any?) -> Int {
        if let i = raw as? Int { return i }
        if let i64 = raw as? Int64 { return Int(i64) }
        if let d = raw as? Double { return Int(d) }
        if let s = raw as? String, let i = Int(s) { return i }
        return 0
    }

    private static func optionalIntValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let i64 = raw as? Int64 { return Int(i64) }
        if let d = raw as? Double { return Int(d) }
        if let s = raw as? String, let i = Int(s) { return i }
        return nil
    }

    private static func stringValue(_ raw: Any?) -> String? {
        if let s = raw as? String, !s.isEmpty { return s }
        return nil
    }
}
