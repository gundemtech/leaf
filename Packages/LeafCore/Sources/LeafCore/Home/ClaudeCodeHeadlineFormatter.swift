//  ClaudeCodeHeadlineFormatter.swift
//  Track 7 P1 — K/M/B compact token formatter (spec OQ-T7-2). Pure function;
//  no localization yet (en-US thresholds). Detail screen reuses the same
//  helper so headline + chart annotations stay consistent.

import Foundation

public enum ClaudeCodeHeadlineFormatter {

    /// Returns e.g. "812 tokens", "52.3K tokens", "2.1M tokens", "3.4B tokens".
    /// Uses 1-digit fractional precision above the K threshold; below 1_000
    /// renders the integer without a separator.
    public static func tokens(_ count: Int) -> String {
        let n = Double(count)
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        formatter.locale = Locale(identifier: "en_US_POSIX")

        switch count {
        case ..<1_000:
            return "\(count) tokens"
        case 1_000..<1_000_000:
            let s = formatter.string(from: NSNumber(value: n / 1_000)) ?? "\(count)"
            return "\(s)K tokens"
        case 1_000_000..<1_000_000_000:
            let s = formatter.string(from: NSNumber(value: n / 1_000_000)) ?? "\(count)"
            return "\(s)M tokens"
        default:
            let s = formatter.string(from: NSNumber(value: n / 1_000_000_000)) ?? "\(count)"
            return "\(s)B tokens"
        }
    }
}
