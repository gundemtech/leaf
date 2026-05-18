//
//  SurfaceCardState.swift
//  Track 7 — render state for one Home surface card. Six terminal cases
//  cover spec §8 matrix (OFF / ON+loading / ON+zero today / ON+zero all-time
//  → reused .enabledEmpty / ON+data / error). Generic over `Payload` so each
//  surface defines its own data carrier without losing exhaustive switch
//  in views.
//

import Foundation

public enum SurfaceCardState<Payload: Equatable & Sendable>: Equatable, Sendable {
    case disabled
    case enabledLoading
    case enabledEmpty  // ON + zero all-time
    case enabledZeroToday  // ON + zero today, may have spark from 7d
    case enabledPopulated(payload: Payload)
    case error(message: String)

    public var isEnabled: Bool {
        if case .disabled = self { return false }
        return true
    }

    public var payload: Payload? {
        if case .enabledPopulated(let p) = self { return p }
        return nil
    }
}
