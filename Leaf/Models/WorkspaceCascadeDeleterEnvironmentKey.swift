//
//  WorkspaceCascadeDeleterEnvironmentKey.swift
//  Leaf
//
//  Track 5 / S8 / T8 — SwiftUI EnvironmentKey for WorkspaceCascadeDeleter.
//
//  Actors can't conform to Observation tracking, so the `.environment(value:)`
//  overload for @Observable doesn't apply. This custom key threads the cascade
//  deleter actor through the environment as an optional Sendable reference so
//  RootView's `.task(id:)` daily-tick scheduler can invoke
//  `.pruneExpiredLeftWorkspaces()` on it alongside the existing
//  TeamEventMirrorRetentionPruner / PendingMarkDoneRetryService daily ticks.
//
//  Optional because the underlying Database open can fail at LeafApp.init
//  (FileKeyStore race, disk pressure); in that case the env value stays nil
//  and the RootView tick path silently skips — same graceful degradation
//  pattern used by `\.attachmentMetadataResolver` /
//  `\.pendingMarkDoneRetryService`.
//

import SwiftUI
import LeafCore

private struct WorkspaceCascadeDeleterEnvironmentKey: EnvironmentKey {
    /// nil default — composition root (LeafApp.init) wires the live deleter
    /// once Database is opened. Snapshot / preview surfaces (which never tick)
    /// can leave this nil safely.
    @MainActor static let defaultValue: WorkspaceCascadeDeleter? = nil
}

extension EnvironmentValues {
    var workspaceCascadeDeleter: WorkspaceCascadeDeleter? {
        get { self[WorkspaceCascadeDeleterEnvironmentKey.self] }
        set { self[WorkspaceCascadeDeleterEnvironmentKey.self] = newValue }
    }
}
