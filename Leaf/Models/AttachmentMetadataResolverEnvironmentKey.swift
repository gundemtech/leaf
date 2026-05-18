//
//  AttachmentMetadataResolverEnvironmentKey.swift
//  Leaf
//
//  Track 5 / S7 H.3 — SwiftUI EnvironmentKey for AttachmentMetadataResolver actor.
//  Actors can't conform to Observable (Observation Tracking), so the
//  `.environment(value:)` overload for @Observable doesn't apply. This
//  custom key threads the resolver through the environment as a Sendable
//  optional — composition root wires the live DB-backed resolver, views
//  consume via `@Environment(\.attachmentMetadataResolver)`.
//
//  Default value is `nil` so views can render gracefully without a resolver
//  wired (e.g., during Phase H rollout or in unit-test snapshots).
//

import SwiftUI
import LeafCore

private struct AttachmentMetadataResolverEnvironmentKey: EnvironmentKey {
    /// Default `nil` — view degrades to "no metadata embed" without crashing.
    /// Production composition root overrides via `.environment(\.attachmentMetadataResolver, …)`.
    static let defaultValue: AttachmentMetadataResolver? = nil
}

extension EnvironmentValues {
    var attachmentMetadataResolver: AttachmentMetadataResolver? {
        get { self[AttachmentMetadataResolverEnvironmentKey.self] }
        set { self[AttachmentMetadataResolverEnvironmentKey.self] = newValue }
    }
}
