//  LinearHeadlineFormatter.swift
//  Track 7 P4 — pure mapper from LinearActivityBreakdown → DetailHeadline.
//  Headline shape: "<N> issue<s> touched" + optional trend with wowDeltaPct
//  and issueCloseStreak. Range parameter included for future per-range
//  customization (e.g. "this week" suffix); v1.0 does not use it.

import Foundation

public enum LinearHeadlineFormatter {
    public static func headline(
        breakdown: LinearActivityBreakdown,
        range: DetailRange
    ) -> DetailHeadline {
        let n = breakdown.issuesTouched
        let value = "\(n) issue\(n == 1 ? "" : "s") touched"
        return DetailHeadline(value: value, trend: makeTrend(breakdown: breakdown))
    }

    private static func makeTrend(breakdown: LinearActivityBreakdown) -> String? {
        var parts: [String] = []
        if let wow = breakdown.wowDeltaPct {
            parts.append(formatWow(wow))
        }
        if let streak = breakdown.issueCloseStreak, streak > 0 {
            parts.append("\(streak)-day close streak")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func formatWow(_ delta: Double) -> String {
        let pct = Int((delta * 100).rounded())
        if pct >= 0 {
            return "+\(pct)% from last week"
        } else {
            return "−\(abs(pct))% from last week"
        }
    }
}
