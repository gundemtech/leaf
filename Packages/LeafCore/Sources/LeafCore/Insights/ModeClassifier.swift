//
//  ModeClassifier.swift
//  LeafCore
//
//  Phase 4.7.C — types-only skeleton под Phase 4.9 derived modes synthesis.
//
//  Mode / Pulse enums + ClassifiedMode struct + ModeClassifier protocol.
//  `DefaultModeClassifier` impl откладывается до 4.9 (substrate ship'ится
//  independently от synthesis). До 4.9 `presence_state.derived_mode` остаётся
//  NULL — column уже nullable из M005 schema migration.
//

import Foundation

/// High-level activity bucket — что юзер делает в моменте, derived от sustained
/// pattern across recent events / app focus / meeting state.
public enum Mode: String, Sendable, Hashable, CaseIterable {
    case code
    case coordination
    case review
    case focus
    case meeting
}

/// Intensity bucket — насколько активно юзер занимается mode'ом.
public enum Pulse: String, Sendable, Hashable, CaseIterable {
    case heavy
    case medium
    case light
}

/// Single classified observation. Phase 4.9 producer кладёт row в новую
/// `mode_history` table + UPSERT'ит `presence_state.derived_mode`.
public struct ClassifiedMode: Sendable, Hashable {
    public let mode: Mode
    public let pulse: Pulse
    /// 0.0..1.0 — soft signal под mode-tinted UI и broadcast filter.
    public let confidence: Double
    /// Epoch ms — момент classify call.
    public let observedAtMs: Int64

    public init(mode: Mode, pulse: Pulse, confidence: Double, observedAtMs: Int64) {
        self.mode = mode
        self.pulse = pulse
        self.confidence = confidence
        self.observedAtMs = observedAtMs
    }
}

/// Phase 4.9 имплементирует `DefaultModeClassifier` поверх Derived Insights queries
/// (recent events distribution + presence_state + app focus). Phase 4.7.C declares
/// protocol; никаких production conformances не существует до 4.9.
public protocol ModeClassifier: Sendable {
    /// Phase 4.9: вернёт ClassifiedMode на основе recent events / presence_state / app focus.
    /// Phase 4.7.C: protocol declared, no impl exists.
    func classify(atMs: Int64) async throws -> ClassifiedMode?
}
