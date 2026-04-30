import Foundation

/// Phase 4.6.C.2 — самое длинное окно внутри `period` без events из Layer B
/// integrations (Linear/GitHub/Slack). Proxy для "deep async work session" —
/// время непрерывной работы без notification-interruption из tracked интеграций.
///
/// Отличается от `FocusSession` (тот про app-switches/idle на уровне macOS):
/// здесь только integration silence. Окно может ограничиваться bounds period'а
/// (gap от period.start до first event, или от last event до period.end —
/// edge case "events нет вовсе" → window = весь period).
public struct UninterruptedWindow: Sendable, Hashable, Codable {
    public let start: Date
    public let end: Date
    public let durationSeconds: Int
    /// Источники с ≥1 event в period (не "connected sources"). Honest signal:
    /// если sourcesActiveInPeriod=["slack"], gap считается только между Slack
    /// events — Linear/GitHub либо disconnected, либо silent весь период.
    public let sourcesActiveInPeriod: [String]

    public init(
        start: Date,
        end: Date,
        durationSeconds: Int,
        sourcesActiveInPeriod: [String]
    ) {
        self.start = start
        self.end = end
        self.durationSeconds = durationSeconds
        self.sourcesActiveInPeriod = sourcesActiveInPeriod
    }
}
