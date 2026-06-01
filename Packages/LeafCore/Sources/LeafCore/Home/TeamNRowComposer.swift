//
//  TeamNRowComposer.swift
//  Track-10 T6 — pure composition helpers for the Home Zone-3 TEAM·N block.
//  Lives in LeafCore so the SwiftUI body (Leaf/Views/.../TeamNBlock.swift)
//  stays a thin shell over testable primitives. Mirrors the Track-10 T5
//  precedent (SinceLastActiveItem composition lives in LeafCore, view
//  consumes outputs).
//

import Foundation

/// Static helpers consumed by `TeamNBlock`. All functions are pure and
/// deterministic within a single launch — `paletteIndex` is documented as
/// drifting across launches due to `String.hashValue` randomization
/// (matches the WithYouOnThis P5 carry trade-off).
public enum TeamNRowComposer {

    /// Maximum number of rows the block renders before the "+N more"
    /// expand footer. Block-level `@State` toggles isExpanded to reveal
    /// the remaining slice inline.
    public static let visibleCap: Int = 5

    /// Composes the secondary line `"<currentApp> · <branch>"` shown below
    /// the teammate's `displayName`. Returns `nil` when both fields are
    /// missing (or empty) so the view can collapse the VStack to a single
    /// row without an empty Text producing visual gap. Empty-string fields
    /// are treated identically to `nil` to guard against producers that
    /// emit `""` rather than `nil` for unset values.
    public static func metaLine(_ snapshot: TeammateSnapshot) -> String? {
        let parts = [snapshot.currentApp, snapshot.branch]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Most-recent-first sort by `lastActivityAtMs`. Stable on ties — when
    /// two teammates share a timestamp, input order is preserved so the
    /// visible-row list doesn't shuffle between refresh ticks.
    public static func sorted(_ snapshots: [TeammateSnapshot]) -> [TeammateSnapshot] {
        // Swift's `sorted` is guaranteed stable for `Array`. Predicate
        // returns `true` when lhs > rhs to flip the natural asc order.
        snapshots.sorted { $0.lastActivityAtMs > $1.lastActivityAtMs }
    }

    /// Returns a 0..<paletteCount index used by the view layer to pick an
    /// avatar tint from `LeafColor` tokens. Deterministic WITHIN a single
    /// launch (`String.hashValue` is randomized across processes, so the
    /// tint may drift between runs — accepted trade-off, matches
    /// WithYouOnThisBlock P5 precedent line 152-156).
    public static func paletteIndex(memberID: String, paletteCount: Int) -> Int {
        guard paletteCount > 0 else { return 0 }
        return abs(memberID.hashValue) % paletteCount
    }

    /// Up to two leading capital letters from the first two whitespace-
    /// separated parts of `displayName`. Falls back to `"?"` when input
    /// is empty or whitespace-only. Matches WithYouOnThisBlock line 175-180
    /// behavior verbatim.
    public static func initials(_ displayName: String) -> String {
        let parts = displayName.split(separator: " ").prefix(2)
        let chars = parts.compactMap { $0.first.map(String.init) }
        let joined = chars.joined().uppercased()
        return joined.isEmpty ? "?" : String(joined.prefix(2))
    }

    /// VoiceOver label for a teammate row. Composes
    /// `<displayName>, <currentApp?>, <branch?>, <relativeTime>` with
    /// graceful nil-skip — never emits `"Sasha, , , 2m ago"` for snapshots
    /// missing currentApp/branch. Caller pre-formats the relative time
    /// via `HomeRelativeTimeFormatter.format(deltaMs:nowMs:)`.
    public static func a11yLabel(
        _ snapshot: TeammateSnapshot,
        relativeTime: String
    ) -> String {
        var parts: [String] = [snapshot.displayName]
        if let app = snapshot.currentApp, !app.isEmpty {
            parts.append(app)
        }
        if let branch = snapshot.branch, !branch.isEmpty {
            parts.append(branch)
        }
        parts.append(relativeTime)
        return parts.joined(separator: ", ")
    }
}
