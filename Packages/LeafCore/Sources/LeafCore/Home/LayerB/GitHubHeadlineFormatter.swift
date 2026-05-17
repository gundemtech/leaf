//  GitHubHeadlineFormatter.swift
//  Track 7 P4 — mirror LinearHeadlineFormatter shape. Headline:
//  "<N> event<s>" + optional trend with wowDeltaPct and commitStreak.

import Foundation

public enum GitHubHeadlineFormatter {
    public static func headline(
        breakdown: GitHubActivityBreakdown,
        range: DetailRange
    ) -> DetailHeadline {
        let n = breakdown.eventsCount
        let value = "\(n) event\(n == 1 ? "" : "s")"
        return DetailHeadline(value: value, trend: makeTrend(breakdown: breakdown))
    }

    private static func makeTrend(breakdown: GitHubActivityBreakdown) -> String? {
        var parts: [String] = []
        if let wow = breakdown.wowDeltaPct {
            parts.append(formatWow(wow))
        }
        if let streak = breakdown.commitStreak, streak > 0 {
            parts.append("\(streak)-day commit streak")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func formatWow(_ delta: Double) -> String {
        let pct = Int((delta * 100).rounded())
        return pct >= 0 ? "+\(pct)% from last week" : "−\(abs(pct))% from last week"
    }
}
