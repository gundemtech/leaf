//
//  TierGateReader.swift
//  Track 5 / S8 / T3 — @Observable wrapper around TierGate static read for
//  SwiftUI binding.
//
//  Per arch reviewer I1: TierGate stays sync struct (UserDefaults reads are
//  thread-safe; actor would push every gate check into await). This Reader
//  is the @MainActor @Observable layer purely for UI binding — observes
//  UserDefaults.didChangeNotification (auto-refresh on `defaults write` from
//  Terminal during QA / Stripe entitlement sync flips) and also exposes
//  manual `refresh()` for callsites that want explicit timing.
//
//  Capability helpers mirror TierGate's static helpers — SwiftUI views bind to
//  `tier` for headline copy and to `canCreateWorkspace` / `canSendDM` /
//  `canAcceptInvite` for button-enabled state.
//

#if canImport(Observation)
import Foundation
import Observation

@MainActor
@Observable
public final class TierGateReader {

    public private(set) var tier: Tier

    public var canCreateWorkspace: Bool { tier == .team }
    public var canSendDM: Bool { tier == .team }
    public var canAcceptInvite: Bool { tier == .team }

    public init() {
        self.tier = TierGate.current()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    /// Re-read TierGate.current() and update `tier` if changed. Safe to call
    /// from any @MainActor context.
    public func refresh() {
        let fresh = TierGate.current()
        if fresh != tier { tier = fresh }
    }
}
#endif
