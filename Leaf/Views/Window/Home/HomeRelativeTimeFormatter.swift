//
//  HomeRelativeTimeFormatter.swift
//  IV.A.1 — stub formatter. Source branch had richer impl; integration uses
//  minimal "Xm/Xh ago" for ResumeHeroBlock / WithYouOnThisBlock until IV.A.2
//  cherry-picks the full source version.
//

import Foundation

enum HomeRelativeTimeFormatter {
    static func format(deltaMs: Int64, nowMs: Int64) -> String {
        let mins = deltaMs / 60_000
        if mins < 1 { return "just now" }
        if mins < 60 { return "\(mins)m ago" }
        let hours = mins / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }
}
