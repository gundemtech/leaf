import Foundation
import GRDB

/// Phase 4.7.B-17 — read-side helper for `get_review_activity` MCP tool.
///
/// Aggregates GitHub review activity across `pr_review_*` event_kinds emitted
/// by Layer B GitHub collector:
/// - `review_submitted` (Phase 4.6.A.1 review delay) → `reviews_submitted_count`.
/// - `pr_review_comment_authored` (Phase 4.7.A wide cheap) → `review_comments_count`.
/// - `pr_review_thread_resolved` — Track C (not yet emitted; helper still
///   counts it so downstream is forward-compatible). Phase 4.7.B will return 0
///   for this aggregate until C lands.
///
/// Лежит в LeafCore (а не в LeafMCP/Tools/), чтобы быть testable из SPM —
/// `LeafMCP` это Xcode target и под `swift test` не собирается. Tool struct
/// `GetReviewActivityTool` в `LeafMCP/Tools/` — пятистрочная обёртка над этим
/// helper'ом.
///
/// ADR-010: helper не парсит bodies / titles / diffs / review-comment text —
/// все aggregates считаются по `event_kind` + numeric `repo`/`pr_number`
/// metadata. `linked_linear_id` уже sanitized GitHub collector'ом
/// (Phase 4.7.A LinearIDExtractor — только matched ID substring,
/// без surrounding text).
public enum ReviewActivityInsights {
    /// Period для `reviewActivity(database:period:repo:)`. Mirror к
    /// `LeafMCP.TimelinePeriod` raw values (today/yesterday/last_7_days) —
    /// LeafMCP target живёт под Xcode и тестируется через Insights helper'ы
    /// в LeafCore (SPM); поэтому enum дублируется здесь, чтобы tool struct
    /// мог `if let p = ReviewActivityPeriod(rawValue: raw)` без cross-target
    /// import'а. Tool обёртка mapper'ит `TimelinePeriod` → `ReviewActivityPeriod`
    /// 1:1 (same raw values).
    public enum ReviewActivityPeriod: String, Sendable {
        case today
        case yesterday
        case last7Days = "last_7_days"

        public func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
            switch self {
            case .today:
                let start = calendar.startOfDay(for: now)
                let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
                return DateInterval(start: start, end: end)
            case .yesterday:
                let todayStart = calendar.startOfDay(for: now)
                let start = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
                return DateInterval(start: start, end: todayStart)
            case .last7Days:
                let end = now
                let start = calendar.date(byAdding: .day, value: -7, to: end) ?? end
                return DateInterval(start: start, end: end)
            }
        }
    }

    /// Aggregate review activity across `pr_review_*` event_kinds for the
    /// given period. Optional `repo` filter narrows aggregation to a single
    /// "owner/name" repo full name.
    ///
    /// Returns payload готовый к сериализации:
    /// ```
    /// {
    ///   "period": String,                                    // echo of period arg
    ///   "from": ISO8601 String,
    ///   "to": ISO8601 String,
    ///   "reviews_submitted_count": Int,
    ///   "review_comments_count": Int,
    ///   "review_thread_resolved_count": Int,                 // always 0 until Track C
    ///   "by_repo": [
    ///     { "repo": String, "reviews": Int, "comments": Int },
    ///     ...
    ///   ],
    ///   "linked_prs": [
    ///     { "repo": String, "pr_number": Int, "linked_linear_id": String },
    ///     ...
    ///   ]
    /// }
    /// ```
    /// Empty events → counts=0, `by_repo=[]`, `linked_prs=[]` — top-level
    /// shape сохраняется (mirror к B-16 zero-data discipline).
    ///
    /// `by_repo` отсортирован по DESC sum(reviews+comments) — top-of-mind
    /// first для AI-клиента читающего ответ. `linked_prs` deduplicated
    /// SELECT DISTINCT по (repo, pr_number, linked_linear_id) и отсортирован
    /// по (repo ASC, pr_number ASC) для детерминизма.
    public static func reviewActivity(
        database: Database,
        period: ReviewActivityPeriod = .today,
        repo: String? = nil,
        now: Date = Date()
    ) throws -> [String: Any] {
        let interval = period.interval(now: now)
        let startMs = Int64(interval.start.timeIntervalSince1970 * 1000)
        let endMs = Int64(interval.end.timeIntervalSince1970 * 1000)

        var reviewsSubmitted = 0
        var reviewComments = 0
        var threadResolved = 0
        var byRepo: [[String: Any]] = []
        var linkedPRs: [[String: Any]] = []

        try database.readSQL { rawDB in
            // 1. Top-level counts per event_kind. Single SQL grouped scan —
            // дешевле трёх отдельных COUNT(*) запросов на one events table scan.
            let countsSQL = """
                SELECT json_extract(\(Schema.Events.payloadJSON), '$.event_kind') AS k, COUNT(*) AS c
                FROM \(Schema.Events.tableName)
                WHERE json_extract(\(Schema.Events.payloadJSON), '$.source') = 'github'
                  AND json_extract(\(Schema.Events.payloadJSON), '$.event_kind') IN ('review_submitted', 'pr_review_comment_authored', 'pr_review_thread_resolved')
                  AND \(Schema.Events.ts) >= ? AND \(Schema.Events.ts) < ?
                  \(repo != nil ? "AND json_extract(\(Schema.Events.payloadJSON), '$.repo') = ?" : "")
                GROUP BY k
                """
            var args: [DatabaseValueConvertible] = [startMs, endMs]
            if let r = repo { args.append(r) }
            let rows = try GRDB.Row.fetchAll(rawDB, sql: countsSQL, arguments: StatementArguments(args))
            for row in rows {
                let kind = row["k"] as? String ?? ""
                let count = (row["c"] as? Int64).map { Int($0) } ?? 0
                switch kind {
                case "review_submitted": reviewsSubmitted = count
                case "pr_review_comment_authored": reviewComments = count
                case "pr_review_thread_resolved": threadResolved = count
                default: break
                }
            }

            // 2. by_repo aggregation — GROUP BY repo, conditional sums.
            // SQLite supports `SUM(CASE WHEN ... THEN 1 ELSE 0 END)` для conditional counts.
            let byRepoSQL = """
                SELECT
                  json_extract(\(Schema.Events.payloadJSON), '$.repo') AS repo,
                  SUM(CASE WHEN json_extract(\(Schema.Events.payloadJSON), '$.event_kind') = 'review_submitted' THEN 1 ELSE 0 END) AS reviews,
                  SUM(CASE WHEN json_extract(\(Schema.Events.payloadJSON), '$.event_kind') = 'pr_review_comment_authored' THEN 1 ELSE 0 END) AS comments
                FROM \(Schema.Events.tableName)
                WHERE json_extract(\(Schema.Events.payloadJSON), '$.source') = 'github'
                  AND json_extract(\(Schema.Events.payloadJSON), '$.event_kind') IN ('review_submitted', 'pr_review_comment_authored', 'pr_review_thread_resolved')
                  AND \(Schema.Events.ts) >= ? AND \(Schema.Events.ts) < ?
                  \(repo != nil ? "AND json_extract(\(Schema.Events.payloadJSON), '$.repo') = ?" : "")
                  AND json_extract(\(Schema.Events.payloadJSON), '$.repo') IS NOT NULL
                  AND json_extract(\(Schema.Events.payloadJSON), '$.repo') != ''
                GROUP BY repo
                ORDER BY (reviews + comments) DESC, repo ASC
                """
            let byRepoRows = try GRDB.Row.fetchAll(rawDB, sql: byRepoSQL, arguments: StatementArguments(args))
            for row in byRepoRows {
                let r = row["repo"] as? String ?? ""
                let rev = (row["reviews"] as? Int64).map { Int($0) } ?? 0
                let com = (row["comments"] as? Int64).map { Int($0) } ?? 0
                byRepo.append([
                    "repo": r,
                    "reviews": rev,
                    "comments": com
                ])
            }

            // 3. linked_prs — distinct (repo, pr_number, linked_linear_id) tuples
            // на pr_* event'ах с непустым linked_linear_id. Phase 4.7.A `pr_opened`
            // / `pr_merged` / `pr_closed` / `commit_pushed` могут нести этот field.
            // Filter: pr_number != "" (commit_pushed без PR context отбрасываем).
            // Period фильтр сохраняется — same window as review aggregates.
            let linkedSQL = """
                SELECT DISTINCT
                  json_extract(\(Schema.Events.payloadJSON), '$.repo') AS repo,
                  json_extract(\(Schema.Events.payloadJSON), '$.number') AS pr_number,
                  json_extract(\(Schema.Events.payloadJSON), '$.linked_linear_id') AS linked
                FROM \(Schema.Events.tableName)
                WHERE json_extract(\(Schema.Events.payloadJSON), '$.source') = 'github'
                  AND json_extract(\(Schema.Events.payloadJSON), '$.linked_linear_id') IS NOT NULL
                  AND json_extract(\(Schema.Events.payloadJSON), '$.linked_linear_id') != ''
                  AND json_extract(\(Schema.Events.payloadJSON), '$.number') IS NOT NULL
                  AND json_extract(\(Schema.Events.payloadJSON), '$.number') != ''
                  AND json_extract(\(Schema.Events.payloadJSON), '$.repo') IS NOT NULL
                  AND json_extract(\(Schema.Events.payloadJSON), '$.repo') != ''
                  AND \(Schema.Events.ts) >= ? AND \(Schema.Events.ts) < ?
                  \(repo != nil ? "AND json_extract(\(Schema.Events.payloadJSON), '$.repo') = ?" : "")
                ORDER BY repo ASC, pr_number ASC
                """
            let linkedRows = try GRDB.Row.fetchAll(rawDB, sql: linkedSQL, arguments: StatementArguments(args))
            for row in linkedRows {
                let r = row["repo"] as? String ?? ""
                // pr_number stored as String ("42") поверх RawEvent [String:String] payload;
                // json_extract returns it as TEXT → cast to Int safely.
                let prNumberRaw = row["pr_number"] as? String ?? ""
                guard let prNumber = Int(prNumberRaw) else { continue }
                let linked = row["linked"] as? String ?? ""
                linkedPRs.append([
                    "repo": r,
                    "pr_number": prNumber,
                    "linked_linear_id": linked
                ])
            }
        }

        let iso = ISO8601DateFormatter()
        return [
            "period": period.rawValue,
            "from": iso.string(from: interval.start),
            "to": iso.string(from: interval.end),
            "reviews_submitted_count": reviewsSubmitted,
            "review_comments_count": reviewComments,
            "review_thread_resolved_count": threadResolved,
            "by_repo": byRepo,
            "linked_prs": linkedPRs
        ]
    }
}
