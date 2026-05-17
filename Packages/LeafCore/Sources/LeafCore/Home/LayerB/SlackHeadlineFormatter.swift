//  SlackHeadlineFormatter.swift
//  Track 7 P4 — mirror Linear/GitHub formatter shape. Headline:
//  "<N> message<s>" + optional trend with wowDeltaPct, huddleMinutes, streak.

import Foundation

public enum SlackHeadlineFormatter {
    public static func headline(
        breakdown: SlackActivityBreakdown,
        range: DetailRange
    ) -> DetailHeadline {
        let n = breakdown.messagesCount
        let value = "\(n) message\(n == 1 ? "" : "s")"
        return DetailHeadline(value: value, trend: makeTrend(breakdown: breakdown))
    }

    private static func makeTrend(breakdown: SlackActivityBreakdown) -> String? {
        var parts: [String] = []
        if let wow = breakdown.wowDeltaPct {
            parts.append(formatWow(wow))
        }
        if breakdown.huddleMinutes > 0 {
            parts.append("\(breakdown.huddleMinutes)m huddle")
        }
        if let streak = breakdown.huddleParticipationStreak, streak > 0 {
            parts.append("\(streak)-day participation streak")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func formatWow(_ delta: Double) -> String {
        let pct = Int((delta * 100).rounded())
        return pct >= 0 ? "+\(pct)% from last week" : "−\(abs(pct))% from last week"
    }
}
