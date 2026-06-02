//
//  ModeClassifier.swift
//  LeafCore
//
//  Phase 4.7.C — types-only skeleton for the Phase 4.9 derived modes synthesis.
//
//  Mode / Pulse enums + ClassifiedMode struct + ModeClassifier protocol.
//  The `DefaultModeClassifier` impl is deferred to 4.9 (the substrate ships
//  independently of synthesis). Until 4.9 `presence_state.derived_mode` stays
//  NULL — the column is already nullable from the M005 schema migration.
//

import Foundation

/// High-level activity bucket — what the user is doing right now, derived from a
/// sustained pattern across recent events / app focus / meeting state.
public enum Mode: String, Sendable, Hashable, CaseIterable {
    case code
    case coordination
    case review
    case focus
    case meeting
}

/// Intensity bucket — how actively the user is engaged in the mode.
public enum Pulse: String, Sendable, Hashable, CaseIterable {
    case heavy
    case medium
    case light
}

/// Single classified observation. The Phase 4.9 producer writes a row into the
/// new `mode_history` table + UPSERTs `presence_state.derived_mode`.
public struct ClassifiedMode: Sendable, Hashable {
    public let mode: Mode
    public let pulse: Pulse
    /// 0.0..1.0 — soft signal for mode-tinted UI and the broadcast filter.
    public let confidence: Double
    /// Epoch ms — the moment of the classify call.
    public let observedAtMs: Int64

    public init(mode: Mode, pulse: Pulse, confidence: Double, observedAtMs: Int64) {
        self.mode = mode
        self.pulse = pulse
        self.confidence = confidence
        self.observedAtMs = observedAtMs
    }
}

/// Phase 4.9 implements `DefaultModeClassifier` on top of Derived Insights queries
/// (recent events distribution + presence_state + app focus). Phase 4.7.C declares
/// the protocol; no production conformances exist until 4.9.
public protocol ModeClassifier: Sendable {
    /// Phase 4.9: returns a ClassifiedMode based on recent events / presence_state / app focus.
    /// Phase 4.7.C: protocol declared, no impl exists.
    func classify(atMs: Int64) async throws -> ClassifiedMode?
}
