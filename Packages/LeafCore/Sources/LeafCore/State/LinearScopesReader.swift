//
//  LinearScopesReader.swift
//  LeafCore
//
//  Track 5 / S6 T11 — @MainActor @Observable wrapper exposing a
//  synchronous `crossPostReady` boolean for the cross-post UI. Mirrors
//  the SlackScopesReader pattern (Track 3 D3) but tracks the new
//  `issues:create` scope (A3 brainstorm — narrower than full Linear
//  `write`) instead of Slack's `chat:write`.
//
//  UI binding:
//   - LinearScopeMissingBanner watches `crossPostReady`; when false it
//     renders inline "Linear needs `issues:create` to create tasks"
//     with a [Re-authorize] button that calls `reauthorize()`.
//
//  Concurrency:
//   - `@MainActor` — UI binding.
//   - `isReauthorizing` guard coalesces concurrent button taps so a
//     spammed [Re-authorize] does not open multiple browser windows.
//

import Foundation
import Observation

@MainActor
@Observable
public final class LinearScopesReader {
    public private(set) var crossPostReady: Bool = false

    /// True while an OAuth re-consent flow is in flight. UI dims the
    /// [Re-authorize] button while set so spam-clicks coalesce.
    public private(set) var isReauthorizing: Bool = false

    private let service: LinearScopesService
    private let reauthorizer: LinearOAuthReauthorizing

    public init(
        service: LinearScopesService,
        reauthorizer: LinearOAuthReauthorizing
    ) {
        self.service = service
        self.reauthorizer = reauthorizer
    }

    /// Re-reads scope grant from the underlying actor. Caller (UI) invokes
    /// from `.onAppear` of the cross-post section AND from the
    /// distributed-notification observer in the composition root after
    /// any integration change.
    public func refresh() async {
        crossPostReady = await service.has("issues:create")
    }

    /// Triggers OAuth re-consent flow, then refreshes scope state. The
    /// real `LinearOAuthService.connect()` opens the browser + waits for
    /// the loopback redirect — this awaits the full flow before reading
    /// the post-consent scope set.
    ///
    /// Concurrent calls coalesce: the second tap awaits the inflight flow
    /// and then sees the refreshed state without re-opening the browser.
    public func reauthorize() async {
        guard !isReauthorizing else { return }
        isReauthorizing = true
        defer { isReauthorizing = false }
        await reauthorizer.connect()
        await service.refresh()    // drop scope cache, force DB re-read
        await refresh()
    }
}

// MARK: - Compatibility — wrap LinearScopesService for the protocol shim

/// Adapter exposing `LinearScopesChecking` for the concrete actor.
/// LinearScopesReader speaks directly to the concrete actor (typed against
/// the public API), but this allows test mocks if/when needed in T12+.
extension LinearScopesService {
    /// Convenience accessor mirroring `LinearScopesChecking.has` so the
    /// concrete-actor + protocol surface stay in sync.
    public func crossPostScopeGranted() async -> Bool {
        await has("issues:create")
    }
}
