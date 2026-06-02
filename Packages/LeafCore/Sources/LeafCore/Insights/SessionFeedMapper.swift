//
//  SessionFeedMapper.swift
//  LeafCore
//
//  Phase 4.10.B — pure stateless mapper from chronological events ->
//  `[ActivitySession]`. ADR-010: reads only safe fields (`window_title`,
//  `browser_url`, `state`); content body / preview / description never.
//
//  Input — generic-shape rows (id / ts / signalType / bundleID / payload),
//  so the mapper can be tested without a DB. The real caller (Prod insights) feeds
//  the result of `SELECT FROM events WHERE signal_type IN ('attention','context')`.
//

import Foundation

/// Generic shape of a row for the mapper — lets tests supply data without
/// being tied to GRDB. id and timestamp are required (sort key + identity);
/// the rest mirrors the `events` table.
public struct SessionMapperRow: Sendable, Hashable {
    public let id: Int64
    public let timestamp: Date
    public let signalType: String
    public let bundleID: String?
    public let payload: [String: String]

    public init(
        id: Int64,
        timestamp: Date,
        signalType: String,
        bundleID: String?,
        payload: [String: String]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.signalType = signalType
        self.bundleID = bundleID
        self.payload = payload
    }
}

public enum SessionFeedMapper {
    /// Fold an ordered feed of attention/context events into a list of
    /// `ActivitySession`. Single-pass O(N) algorithm.
    ///
    /// Behavior:
    /// * A run of consecutive attention events with the same (bundle, contextKey)
    ///   and a gap ≤ `gapThresholdSec` — one session.
    /// * A bundle change, a contextKey change (window_title or browser_url),
    ///   `signal_type=context` with `state=idle`, or a gap > `gapThresholdSec` —
    ///   closes the current session and opens a new one.
    /// * Sessions with `duration < minDurationSec` are filtered out (guards against
    ///   instantaneous switches).
    ///
    /// `referenceEnd` — the moment up to which it makes sense to "stretch" the last
    /// open session. Without it the trailing session gets `end = lastEventTs`
    /// (duration 0) and is cut by the minimum-duration filter, so the caller
    /// usually passes `Date()` or the upper bound of the period.
    public static func map(
        rows: [SessionMapperRow],
        classifier: any AppCategoryClassifier = EmptyAppCategoryClassifier(),
        gapThresholdSec: TimeInterval = 90,
        minDurationSec: TimeInterval = 5,
        referenceEnd: Date? = nil
    ) -> [ActivitySession] {
        guard !rows.isEmpty else { return [] }

        let sorted = rows.sorted { $0.timestamp < $1.timestamp }
        let refEnd = referenceEnd ?? sorted.last!.timestamp

        var open: OpenSession?
        var result: [ActivitySession] = []

        for row in sorted {
            switch row.signalType {
            case "context":
                // Idle context = hard boundary. "active" / others — ignored:
                // the next attention event itself starts a new session if the key didn't match.
                if row.payload["state"] == "idle", let s = open {
                    result.append(s.close(end: clamp(s.lastEventTs, max: row.timestamp, refEnd: refEnd)))
                    open = nil
                }

            case "attention":
                guard let bundleID = row.bundleID, !bundleID.isEmpty else { continue }
                let contextKey = extractContextKey(payload: row.payload)
                let category = classifier.category(for: bundleID)

                if var s = open {
                    let gap = row.timestamp.timeIntervalSince(s.lastEventTs)
                    let sameKey = s.bundleID == bundleID && s.contextKey == contextKey

                    if sameKey && gap <= gapThresholdSec {
                        s.lastEventTs = row.timestamp
                        s.eventCount += 1
                        open = s
                    } else {
                        // Close the current session and open a new one. The end point depends on
                        // whether the gap exceeded the threshold (meaning the session
                        // quietly died somewhere in the middle of the gap — we cap the duration).
                        let end: Date
                        if gap > gapThresholdSec {
                            end = min(s.lastEventTs.addingTimeInterval(gapThresholdSec), row.timestamp)
                        } else {
                            end = row.timestamp
                        }
                        result.append(s.close(end: end))
                        open = OpenSession(
                            id: row.id,
                            bundleID: bundleID,
                            category: category,
                            contextKey: contextKey,
                            start: row.timestamp,
                            lastEventTs: row.timestamp,
                            eventCount: 1
                        )
                    }
                } else {
                    open = OpenSession(
                        id: row.id,
                        bundleID: bundleID,
                        category: category,
                        contextKey: contextKey,
                        start: row.timestamp,
                        lastEventTs: row.timestamp,
                        eventCount: 1
                    )
                }

            default:
                continue
            }
        }

        // Trailing session: stretch up to `min(lastEventTs + gap, refEnd)`.
        // This gives an ongoing session a visible duration ("you're here ~30s") without
        // an optimistic "you've been here for 4 hours" if the last event is old.
        if let s = open {
            let trailingEnd = min(s.lastEventTs.addingTimeInterval(gapThresholdSec), refEnd)
            result.append(s.close(end: max(s.lastEventTs, trailingEnd)))
        }

        return result.filter { $0.duration >= minDurationSec }
    }

    // MARK: - Internal helpers

    private struct OpenSession {
        let id: Int64
        let bundleID: String
        let category: AppCategory
        let contextKey: String?
        let start: Date
        var lastEventTs: Date
        var eventCount: Int

        func close(end: Date) -> ActivitySession {
            ActivitySession(
                id: id,
                bundleID: bundleID,
                category: category,
                contextLabel: contextKey,
                start: start,
                end: end,
                eventCount: eventCount
            )
        }
    }

    /// Window title takes priority, browser_url is the fallback. Empty / whitespace-only
    /// strings are treated as absent — otherwise "" and nil would yield different sessions.
    private static func extractContextKey(payload: [String: String]) -> String? {
        if let title = payload["window_title"], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        if let url = payload["browser_url"], !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return url
        }
        return nil
    }

    /// `lastEventTs <= candidate <= refEnd` — guards against negative durations
    /// and overshooting past the sampling period.
    private static func clamp(_ lastEventTs: Date, max candidate: Date, refEnd: Date) -> Date {
        let upper = min(candidate, refEnd)
        return Swift.max(lastEventTs, upper)
    }
}
