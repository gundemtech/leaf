//
//  TierGate.swift
//  Track 5 / S8 / T3 — local client-side tier gate (MVP honor-system).
//
//  Per spec §2 + §10.1: bypassable via `defaults write tech.gundem.leaf tier team`.
//  Acceptable for MVP per contract §15.3 (Stripe post-launch). JWT tier claim
//  scaffold (T2 Auth Hook in leaf-relay) ready for server-side enforcement
//  flip-on when Stripe wires.
//
//  Per arch reviewer I1: **not an actor** — UserDefaults reads are sync +
//  thread-safe; actor overhead would push every check into `await` and force
//  every callsite (modal gates, send-button enabled state, NavigationLink
//  predicates) into Task contexts. The static struct fits the read-only,
//  zero-state nature of the check.
//

import Foundation

public enum TierGate {

    /// UserDefaults key under the app's standard suite. Persisted rawValue is
    /// either `"free"` or `"team"`; any other string (including legacy `"pro"`
    /// from S8 draft phase) falls back to `defaultTier` per cross-spec reviewer
    /// IMP-1.
    public static let userDefaultsKey = "tier"

    /// Default returned when UserDefaults has no value OR an unknown rawValue.
    /// Per contract §15.3 — MVP early-access flows ship as Team to avoid
    /// regressing existing alpha testers when T3→T4 wiring lands.
    public static let defaultTier: Tier = .team

    /// Reads the current effective tier. Sync — UserDefaults reads are
    /// thread-safe; callers can use this from any thread / actor context.
    public static func current() -> Tier {
        guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
              let tier = Tier(rawValue: raw) else {
            return defaultTier
        }
        return tier
    }

    // MARK: - Capability helpers

    /// Workspace creation requires Team tier (UC-T5-7 / §10.1).
    public static func canCreateWorkspace() -> Bool { current() == .team }

    /// Direct messaging requires Team tier (UC-T5-7 / §10.1).
    public static func canSendDM() -> Bool { current() == .team }

    /// Joining an existing workspace via invite requires Team tier
    /// (OQ-T5-6 free-tier UX resolution — invite acceptance is gated, not the
    /// invite generation flow).
    public static func canAcceptInvite() -> Bool { current() == .team }

    // MARK: - Dev/QA flip

    /// Dev/QA flip — for UC-T5-7 acceptance gate smoke (G22 negative path).
    /// Production Stripe wire-up replaces this with entitlement state sync.
    public static func setTier(_ tier: Tier) {
        UserDefaults.standard.set(tier.rawValue, forKey: userDefaultsKey)
    }
}
