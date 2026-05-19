//
//  Tier.swift
//  Track 5 / S8 / T3 — local tier enum for MVP honor-system gating.
//
//  Per Track 5 contract §15.1: two-tier model — Free (default until invited
//  / accepted) vs Team (paid; $30/seat, min 2 seats). MVP early-access
//  semantics per §15.3 ship with default = `.team` so existing alpha
//  testers don't lose feature access at the T3→T4 wiring flip; legacy
//  `pro` UserDefaults values (left over from S8 draft phase before
//  cross-spec reviewer IMP-1 collapsed `pro`/`enterprise` into `team`)
//  normalize to the default in `TierGate.current()`.
//
//  rawValue strings are persisted in UserDefaults (key `tier`) and surface
//  in the JWT `tier` claim once Auth Hook starts honouring Stripe state
//  (T2 substrate ready; flip-on post-launch).
//

import Foundation

public enum Tier: String, Codable, Sendable, CaseIterable {
    case free
    case team
}
