//  ClaudeCodeHeadlineFormatter.swift
//  Track 7 P1 — K/M/B compact token formatter (spec OQ-T7-2). Pure function;
//  no localization yet (en-US thresholds). Detail screen reuses the same
//  helper so headline + chart annotations stay consistent.

public enum ClaudeCodeHeadlineFormatter {

    /// Returns e.g. "812 tokens", "52.3K tokens", "2.1M tokens", "3.4B tokens".
    /// Uses 1-digit fractional precision above the K threshold; below 1_000
    /// renders the integer without a separator.
    ///
    /// `String(format: "%.1f", ...)` uses the C locale internally so the
    /// decimal separator is always `.` regardless of user locale — matches
    /// the intent we previously expressed via en_US_POSIX-pinned
    /// NumberFormatter without per-call allocation.
    public static func tokens(_ count: Int) -> String {
        let n = Double(count)
        switch count {
        case ..<1_000:
            return "\(count) tokens"
        case 1_000..<1_000_000:
            return String(format: "%.1fK tokens", n / 1_000)
        case 1_000_000..<1_000_000_000:
            return String(format: "%.1fM tokens", n / 1_000_000)
        default:
            return String(format: "%.1fB tokens", n / 1_000_000_000)
        }
    }
}
