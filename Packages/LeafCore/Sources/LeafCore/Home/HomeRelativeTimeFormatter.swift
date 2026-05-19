//
//  HomeRelativeTimeFormatter.swift
//  Phase 8.9 (P9) — C-22 unification of formatRelative across Home blocks.
//  Single bucket ladder: now / Nm ago / Nh ago / yesterday / N days ago /
//  absolute "MMM d" (en_US_POSIX cached). Pure function over Int64
//  millisecond inputs — deterministic and unit-testable.
//

import Foundation

public enum HomeRelativeTimeFormatter {
    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM d"
        return f
    }()

    /// Returns a bucketed relative-time label.
    /// - Parameters:
    ///   - deltaMs: positive milliseconds elapsed (nowMs − eventMs).
    ///       Clock-skew protected via `max(0, …)`.
    ///   - nowMs: current epoch milliseconds. Used to anchor the absolute
    ///       fallback past 7 days.
    public static func format(deltaMs: Int64, nowMs: Int64) -> String {
        let delta = max(0, deltaMs)
        let seconds = delta / 1000
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 2 { return "yesterday" }
        if days < 7 { return "\(days) days ago" }
        let eventMs = nowMs - delta
        return absoluteFormatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(eventMs) / 1000)
        )
    }
}
