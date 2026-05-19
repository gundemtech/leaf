//
//  SubmitToWaitlistEnvironmentKey.swift
//  Leaf
//
//  Track 5 / S8 / T4 — EnvironmentKey for the waitlist-submit closure used by
//  UpgradeModal. The closure wraps `SupabaseClient.submitToWaitlist(email:)`
//  via the composition root, keeping UpgradeModal callsites SwiftUI-pure (no
//  actor / network primitives imported into View files).
//
//  Default value short-circuits with a transport-error Result so the modal
//  surfaces a generic failure if T4 wiring is skipped in tests / previews.
//

import SwiftUI
import LeafCore

/// Async closure type — matches `UpgradeModal.onSubmitEmail` signature.
typealias SubmitToWaitlistClosure = @Sendable (String) async -> Result<Void, Error>

private struct SubmitToWaitlistEnvironmentKey: EnvironmentKey {
    /// Default returns `.failure` so a missing-wiring path doesn't silently
    /// pretend success. Composition root in `LeafApp.body` overrides via
    /// `.environment(\.submitToWaitlist, ...)` capturing supabaseClient.
    static let defaultValue: SubmitToWaitlistClosure = { _ in
        .failure(SupabaseError.transport(reason: "submitToWaitlist closure not wired in composition root"))
    }
}

extension EnvironmentValues {
    var submitToWaitlist: SubmitToWaitlistClosure {
        get { self[SubmitToWaitlistEnvironmentKey.self] }
        set { self[SubmitToWaitlistEnvironmentKey.self] = newValue }
    }
}
