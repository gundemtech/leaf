//
//  MirrorRetentionConfig.swift
//  Track 5 / S8 / T10 — user-configurable retention for the auto-shared
//  team events mirror. Closes 2× deferral: contract §13:479 (originally
//  promised in S5, deferred to S7 with M025 carry-over; deferred again
//  to S8 by user mandate per spec §6 deferred-to-S8).
//
//  Allowed values: 30 / 60 / 90 / 180 / 365 days. Default 90.
//  Invalid stored values silently fall back to default (mirrors
//  `TierGate.current()` pattern — UserDefaults wrapper with allow-list
//  guard; per cross-spec reviewer IMP-1 unknown rawValues never throw).
//
//  Direct messages are NOT subject to this picker — they're kept forever
//  per Track 5 contract privacy posture (separate retention path).
//
//  Per `TierGate.swift` precedent: **not an actor** — UserDefaults reads
//  are sync + thread-safe. The static enum fits the read-only,
//  zero-instance-state nature of the check; callers (pruner closure,
//  Settings picker, tests) read directly without `await` overhead.
//

import Foundation

/// User-configurable retention for the auto-shared team events mirror.
/// Per Track 5 contract §13:479 + S5 spec §6 (deferred-to-S8).
public enum MirrorRetentionConfig {

    /// UserDefaults key under the app's standard suite. Persisted Int is
    /// either one of `allowedValues`; any other value (including 0 / -1 /
    /// 42 / 999) falls back to `defaultDays`.
    public static let userDefaultsKey = "mirror_retention_days"

    /// Allowed picker values per spec §3.5 — 30/60/90/180/365.
    public static let allowedValues: [Int] = [30, 60, 90, 180, 365]

    /// Default returned when UserDefaults has no value OR an unknown value.
    /// 90 days matches the pre-T10 hardcoded `defaultRetentionDays` in
    /// `TeamEventMirrorRetentionPruner` (no behaviour change for users who
    /// never open the picker).
    public static let defaultDays: Int = 90

    /// Reads the current effective retention. Sync — UserDefaults reads are
    /// thread-safe; callers can use this from any thread / actor context.
    /// Used by `TeamEventMirrorRetentionPruner` via injected closure.
    public static func retentionDays() -> Int {
        let stored = UserDefaults.standard.integer(forKey: userDefaultsKey)
        guard allowedValues.contains(stored) else { return defaultDays }
        return stored
    }

    /// Persists a new retention value. No-op if `days` is not in
    /// `allowedValues` (defence-in-depth — Settings picker only offers
    /// allowed values; this guard catches programmatic misuse + dev/QA
    /// `defaults write` typos).
    public static func setRetentionDays(_ days: Int) {
        guard allowedValues.contains(days) else { return }
        UserDefaults.standard.set(days, forKey: userDefaultsKey)
    }
}
