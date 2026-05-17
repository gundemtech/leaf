//
//  SessionFeedMapper.swift
//  LeafCore
//
//  Phase 4.10.B — pure stateless mapper из chronological events ->
//  `[ActivitySession]`. ADR-010: читает только safe-fields (`window_title`,
//  `browser_url`, `state`); content body / preview / description никогда.
//
//  Вход — generic-shape rows (id / ts / signalType / bundleID / payload),
//  чтобы mapper тестировался без БД. Реальный caller (Prod insights) кормит
//  результат `SELECT FROM events WHERE signal_type IN ('attention','context')`.
//

import Foundation

/// Generic shape строки для mapper'а — позволяет тестам подавать данные без
/// привязки к GRDB. id и timestamp обязательны (sort key + identity);
/// остальное — как в `events` table.
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
    /// Сложить упорядоченную ленту attention/context events в список
    /// `ActivitySession`. Алгоритм single-pass O(N).
    ///
    /// Поведение:
    /// * Run consecutive attention events с одинаковым (bundle, contextKey)
    ///   и gap'ом ≤ `gapThresholdSec` — одна сессия.
    /// * Смена bundle, смена contextKey (window_title или browser_url),
    ///   `signal_type=context` с `state=idle`, либо gap > `gapThresholdSec` —
    ///   закрытие текущей и открытие новой.
    /// * Сессии с `duration < minDurationSec` отсеиваются (защита от
    ///   мгновенных переключений).
    ///
    /// `referenceEnd` — момент, до которого имеет смысл "тянуть" последнюю
    /// открытую сессию. Без него trailing session получает `end = lastEventTs`
    /// (длительность 0) и режется минимальным фильтром, поэтому caller
    /// обычно передаёт `Date()` или верхнюю границу периода.
    public static func map(
        rows: [SessionMapperRow],
        classifier: any AppCategoryClassifier = EmptyAppCategoryClassifier(),
        gapThresholdSec: TimeInterval = 90,
        minDurationSec: TimeInterval = 5,
        referenceEnd: Date? = nil
    ) -> [ActivitySession] {
        guard !rows.isEmpty else { return [] }

        let sorted = rows.sorted { $0.timestamp < $1.timestamp }
        // Reason: `guard !rows.isEmpty` above guarantees `sorted.last != nil`.
        // swiftlint:disable:next force_unwrapping
        let refEnd = referenceEnd ?? sorted.last!.timestamp

        var open: OpenSession?
        var result: [ActivitySession] = []

        for row in sorted {
            switch row.signalType {
            case "context":
                // Idle context = жёсткая граница. "active" / прочие — игнор:
                // следующий attention сам начнёт новую сессию если key не совпал.
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
                        // Закрываем текущую и открываем новую. End point зависит от
                        // того, успел ли gap превысить threshold (значит сессия
                        // тихо умерла где-то в середине gap'а — кэпим длительность).
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

        // Trailing session: тянем до `min(lastEventTs + gap, refEnd)`.
        // Это даёт ongoing-сессии видимую длительность ("вы здесь ~30s") без
        // оптимистичного "вы тут уже 4 часа" если последний event давний.
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

    /// Window title в приоритете, browser_url fallback. Пустые / whitespace-only
    /// строки трактуем как отсутствие — иначе "" и nil дали бы разные сессии.
    private static func extractContextKey(payload: [String: String]) -> String? {
        if let title = payload["window_title"], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        if let url = payload["browser_url"], !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return url
        }
        return nil
    }

    /// `lastEventTs <= candidate <= refEnd` — защита от негативных длительностей
    /// и overshoot'а за период выборки.
    private static func clamp(_ lastEventTs: Date, max candidate: Date, refEnd: Date) -> Date {
        let upper = min(candidate, refEnd)
        return Swift.max(lastEventTs, upper)
    }
}
