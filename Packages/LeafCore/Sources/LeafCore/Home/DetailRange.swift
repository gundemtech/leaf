//
//  DetailRange.swift
//  Track 7 — detail-screen time window (spec §5.1). Pure value type with
//  a single `interval(now:calendar:)` derivation: detail VMs feed `now =
//  Date()` and use a calendar reflecting user locale; tests pin both
//  parameters to assert deterministic boundaries.
//

import Foundation

public enum DetailRange: String, CaseIterable, Hashable, Codable, Sendable, Identifiable {
    case today, week, month

    public var id: String { rawValue }

    /// Spec §A4 — Week is the contract-wide default. Phase-specific
    /// overrides (e.g. Calendar tab) live in the per-screen view-model.
    public static let `default`: DetailRange = .week

    /// `start` snaps to a canonical boundary (today midnight / week start /
    /// month first); `end` is `now`. View-models pass `now = Date()` and
    /// `calendar = Calendar.current` in production.
    public func interval(now: Date, calendar: Calendar) -> DateInterval {
        let start: Date
        switch self {
        case .today:
            start = calendar.startOfDay(for: now)
        case .week:
            start =
                calendar.dateInterval(of: .weekOfYear, for: now)?.start
                ?? calendar.startOfDay(for: now)
        case .month:
            start =
                calendar.dateInterval(of: .month, for: now)?.start
                ?? calendar.startOfDay(for: now)
        }
        return DateInterval(start: start, end: now)
    }
}
