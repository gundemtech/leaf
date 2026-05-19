//
//  PendingMarkDoneRetryServiceEnvironmentKey.swift
//  Leaf
//
//  Track 5 / S8 T6 — SwiftUI EnvironmentKey for PendingMarkDoneRetryService.
//
//  Actors can't conform to Observation tracking, so the `.environment(value:)`
//  overload for @Observable doesn't apply. This custom key threads the
//  retry-queue actor through the environment as an optional Sendable reference
//  so RootView's `.task(id:)` daily-tick scheduler can invoke `.tick()` on it
//  alongside the existing TeamEventMirrorRetentionPruner pruner tick.
//
//  Optional because the underlying Database open can fail at LeafApp.init
//  (FileKeyStore race, disk pressure); in that case the env value stays nil
//  and the RootView tick path silently skips — same graceful degradation
//  pattern used by `\.attachmentMetadataResolver`.
//

import SwiftUI
import LeafCore

private struct PendingMarkDoneRetryServiceEnvironmentKey: EnvironmentKey {
    /// nil default — composition root (LeafApp.init) wires the live service
    /// once Database is opened. Snapshot / preview surfaces (which never tick)
    /// can leave this nil safely.
    @MainActor static let defaultValue: PendingMarkDoneRetryService? = nil
}

extension EnvironmentValues {
    var pendingMarkDoneRetryService: PendingMarkDoneRetryService? {
        get { self[PendingMarkDoneRetryServiceEnvironmentKey.self] }
        set { self[PendingMarkDoneRetryServiceEnvironmentKey.self] = newValue }
    }
}
