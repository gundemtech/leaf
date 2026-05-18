//
//  WorkStateCardViewModel.swift
//  Track 7 P3 — stateless mapper InsightsSnapshot → WorkStateSummary +
//  headline / sub-line formatter for WorkStateCard. Namespace enum (not a
//  class) because the mapping is pure — same pattern as
//  ClaudeCodeSurfaceCardViewModel from P1.
//
//  Card visibility is unconditional (no enable toggle), but the headline
//  composition rule emits four shapes from §3.2 of the P3 spec:
//
//    Q=0, B=0 → "All clear"
//    Q>0, B=0 → "{Q} open question{s}"
//    Q=0, B>0 → "{B} blocker{s}"
//    Q>0, B>0 → "{Q} open question{s} · {B} blocker{s}"
//

import Foundation
import LeafCore

enum WorkStateCardViewModel {
    /// Map the snapshot to the Work State summary. `snapshot.workState` is
    /// nil for fresh DBs / iOS-future / stub conformer paths — collapse to
    /// `.empty` so the headline is "All clear" rather than rendering nothing.
    static func state(snapshot: InsightsSnapshot) -> WorkStateSummary {
        snapshot.workState ?? .empty
    }
}

/// Pure formatter — separated from the mapper for testability and to keep the
/// `nowMs` injection out of the namespace enum signature.
enum WorkStateHeadlineFormatter {
    /// Spec §3.2 — headline composition.
    static func headline(_ summary: WorkStateSummary) -> String {
        let q = summary.openQuestionsCount
        let b = summary.openBlockersCount
        switch (q, b) {
        case (0, 0):
            return "All clear"
        case (let q, 0) where q > 0:
            return "\(q) open question\(q == 1 ? "" : "s")"
        case (0, let b) where b > 0:
            return "\(b) blocker\(b == 1 ? "" : "s")"
        default:
            return "\(q) open question\(q == 1 ? "" : "s") · \(b) blocker\(b == 1 ? "" : "s")"
        }
    }

    /// Spec §3.3 — sub-line text. Truncates excerpt at 60 chars. Returns nil
    /// when no last decision is set or excerpt is empty.
    static func subLine(_ summary: WorkStateSummary, nowMs: Int64) -> String? {
        guard let raw = summary.lastDecisionExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }
        let trimmed = raw.count > 60 ? String(raw.prefix(60)) + "…" : raw
        return "Last decision: \"\(trimmed)\""
    }

    /// Spec §3.3 — sub-line color is tertiary (greyed) when the decision is
    /// older than 7 days.
    static let staleBoundaryMs: Int64 = 7 * 24 * 60 * 60 * 1_000

    static func subLineIsStale(_ summary: WorkStateSummary, nowMs: Int64) -> Bool {
        guard let ageMs = summary.lastDecisionAgeMs else { return false }
        return ageMs > staleBoundaryMs
    }
}
