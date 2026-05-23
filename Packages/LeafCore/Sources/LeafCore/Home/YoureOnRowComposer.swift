//
//  YoureOnRowComposer.swift
//  Track-10 T7 — pure-function composition helpers for the Home YOU'RE ON
//  block. Extracted to LeafCore for testability (precedent: T6
//  TeamNRowComposer). The SwiftUI body in
//  `Leaf/Views/Window/Home/Blocks/YoureOnBlock.swift` is a thin shell over
//  these primitives.
//

import Foundation

/// Static helpers consumed by `YoureOnBlock`. All functions are pure and
/// deterministic given the same inputs.
public enum YoureOnRowComposer {

    /// Composes "GUN-50 · feature/x · +5 ahead of main". Skips zero/missing
    /// components. Returns `nil` when all three components are absent →
    /// caller routes to empty state.
    public static func composeTaskLine(
        _ taskIdentity: TaskIdentity,
        gitDelta: GitDeltaSnapshot?
    ) -> String? {
        var parts: [String] = []
        if let linearID = taskIdentity.linearID, !linearID.isEmpty {
            parts.append(linearID)
        }
        if let branch = taskIdentity.branch, !branch.isEmpty {
            parts.append(branch)
        }
        if let delta = gitDelta, delta.commitsAhead > 0, let mergeBase = delta.mergeBase {
            parts.append("+\(delta.commitsAhead) ahead of \(refBasename(mergeBase))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Composes "Started 09:18 · 1h 32m focused so far". Returns `nil` when
    /// `sessionStartMs == 0` (no IDE attention today). Drops "focused so far"
    /// suffix when `focusedMin == 0`.
    public static func composeSessionLine(
        sessionStartMs: Int64,
        focusedMin: Int,
        now: Date,
        calendar: Calendar
    ) -> String? {
        guard sessionStartMs > 0 else { return nil }
        let startTime = formatSessionStart(sessionStartMs, calendar: calendar)
        var parts: [String] = ["Started \(startTime)"]
        if focusedMin > 0 {
            parts.append("\(formatFocusedMin(focusedMin)) focused so far")
        }
        return parts.joined(separator: " · ")
    }

    /// Composes "Open files: A.swift · B.swift · C.swift". Returns `nil` when
    /// `files` is empty.
    public static func composeFilesLine(_ files: [String]) -> String? {
        guard !files.isEmpty else { return nil }
        return "Open files: " + files.joined(separator: " · ")
    }

    /// Formats `ms` as "HH:mm" in the given calendar's timezone.
    ///
    /// Per-call `DateFormatter` allocation (NOT cached static — F-CTO-C
    /// resolution): timezone is derived from the injected calendar param, and
    /// DateFormatter instances are NOT thread-safe for mutation (timezone
    /// setter race in concurrent SwiftUI body evaluation). Per-call
    /// construction cost is negligible for 1-2 calls per refresh tick;
    /// correctness wins over micro-optimization. If profiling shows a hot
    /// path, switch to a per-timezone cache (`[TimeZone: DateFormatter]`)
    /// post-ship.
    public static func formatSessionStart(_ ms: Int64, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        // POSIX locale prevents the user's systemwide region settings from
        // overriding the 24h `HH:mm` template (without this, an en_US user
        // sees "8:58 AM" instead of "09:18").
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    /// Formats `min` as "Xh Ym" or "Nm" (empty when zero).
    public static func formatFocusedMin(_ min: Int) -> String {
        guard min > 0 else { return "" }
        let hours = min / 60
        let mins = min % 60
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    /// Strips a ref to its last path component ("origin/main" → "main").
    /// Mirrors `ResumeHeroBlock.refBasename(_:)` file-local helper — promoted
    /// to LeafCore for testability and reuse. Rule-of-three extraction carry
    /// (C-T7-3): if a third caller appears, retire ResumeHero's file-local
    /// copy in favor of this one.
    public static func refBasename(_ ref: String) -> String {
        let segments = ref.split(separator: "/")
        return segments.last.map(String.init) ?? ref
    }

    /// Composes a VoiceOver-readable a11y label with graceful nil-skip per
    /// component. " · " separators translated to ", " for natural speech.
    public static func a11yLabel(
        _ taskIdentity: TaskIdentity,
        gitDelta: GitDeltaSnapshot?,
        sessionStartMs: Int64,
        focusedMin: Int,
        openFiles: [String],
        now: Date,
        calendar: Calendar
    ) -> String {
        var parts: [String] = []
        if let task = composeTaskLine(taskIdentity, gitDelta: gitDelta) {
            parts.append(
                "Working on " + task.replacingOccurrences(of: " · ", with: ", "))
        }
        if let session = composeSessionLine(
            sessionStartMs: sessionStartMs, focusedMin: focusedMin,
            now: now, calendar: calendar)
        {
            parts.append(session.replacingOccurrences(of: " · ", with: ", "))
        }
        if let files = composeFilesLine(openFiles) {
            parts.append(files.replacingOccurrences(of: " · ", with: ", "))
        }
        return parts.joined(separator: ". ")
    }
}
