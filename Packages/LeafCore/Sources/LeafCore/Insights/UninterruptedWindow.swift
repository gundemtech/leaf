import Foundation

/// Phase 4.6.C.2 — the longest window inside `period` with no events from Layer B
/// integrations (Linear/GitHub/Slack). A proxy for a "deep async work session" —
/// the span of uninterrupted work with no notification-interruption from tracked integrations.
///
/// Differs from `FocusSession` (which is about app-switches/idle at the macOS level):
/// here it's only integration silence. The window can be bounded by the period bounds
/// (gap from period.start to the first event, or from the last event to period.end —
/// edge case "no events at all" → window = the entire period).
public struct UninterruptedWindow: Sendable, Hashable, Codable {
    public let start: Date
    public let end: Date
    public let durationSeconds: Int
    /// Sources with ≥1 event in the period (not "connected sources"). Honest signal:
    /// if sourcesActiveInPeriod=["slack"], the gap is computed only between Slack
    /// events — Linear/GitHub are either disconnected or silent for the entire period.
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
