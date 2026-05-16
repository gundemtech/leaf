//
//  SlackChannelsReader.swift
//  LeafCore
//
//  Track 5 / S6 T11 — @MainActor @Observable wrapper that backs the
//  ChannelsPickerSection in SendDirectMessageSheet. Fetches the viewer's
//  accessible Slack channels via a `SlackChannelsProviding` impl and
//  caches them for 5 minutes (A8 brainstorm — fetch-on-connect + lazy
//  stale-while-revalidate so first Send-sheet open after cold launch
//  doesn't spin).
//
//  Lifecycle:
//   - `refreshOnConnect()` — called from the OAuth success path so the
//     first Send sheet open has channels already in memory.
//   - `refreshIfStale()` — called from the Send sheet `.task` modifier;
//     no-op if the cache is younger than `ttl`.
//
//  Concurrency:
//   - `@MainActor` because SwiftUI views bind to its `channels` / `error`
//     state via @Observable.
//   - `isLoading` guards against concurrent fetches storming the provider
//     (e.g. user spam-clicking the picker chevron). The second concurrent
//     call exits early without firing another request.
//
//  Errors:
//   - `provider.fetchAccessibleChannels()` throw → `error` populated with
//     `localizedDescription`. Previously-fetched `channels` are preserved
//     (transient network blip should not blank the picker).
//
//  Production impl of `SlackChannelsProviding` lives in `LeafCorePrivate`
//  (calls `conversations.list` with `types=public_channel,private_channel`
//  + filters to channels the bot/user can post into). LeafCore ships only
//  the protocol + an empty-list stub.
//

import Foundation
import Observation

@MainActor
@Observable
public final class SlackChannelsReader {
    /// Identifiable so SwiftUI `ForEach` can key on `.id` directly.
    /// Sendable + Equatable for safe transport across actor hops + test
    /// expectations.
    public struct SlackChannel: Identifiable, Sendable, Equatable, Hashable {
        public let id: String           // C-prefix Slack channel ID
        public let name: String         // e.g. "leaf-architecture" (raw, no leading "#")
        public let isPrivate: Bool

        public init(id: String, name: String, isPrivate: Bool) {
            self.id = id
            self.name = name
            self.isPrivate = isPrivate
        }
    }

    public private(set) var channels: [SlackChannel] = []
    public private(set) var lastFetchedAt: Date?
    public private(set) var error: String?

    /// True iff a `refresh()` is currently in flight. Computed from the
    /// inflight Task so SwiftUI bindings keep observing the same property.
    /// The setter is intentionally absent — the inflight Task is the
    /// single source of truth.
    public var isLoading: Bool { inflight != nil }

    /// Inflight Task tracked so concurrent refresh callers AWAIT the
    /// shared fetch rather than no-op out via an `isLoading` guard. The
    /// prior guard pattern made the second caller exit early — they then
    /// saw an empty state because the first call hadn't completed yet.
    /// Per actor reentrancy semantics, the second concurrent caller
    /// must coalesce by awaiting the existing Task's value.
    private var inflight: Task<[SlackChannel], Error>?

    private let provider: SlackChannelsProviding
    private let ttl: TimeInterval
    private let clock: @Sendable () -> Date

    public init(
        provider: SlackChannelsProviding,
        ttl: TimeInterval = 300,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.ttl = ttl
        self.clock = clock
    }

    /// Called from the OAuth success path so the first Send sheet open
    /// doesn't show a spinner. Bypasses the TTL guard.
    public func refreshOnConnect() async {
        await refresh()
    }

    /// Called from the Send sheet `.task` modifier. No-op if a successful
    /// fetch landed less than `ttl` ago.
    public func refreshIfStale() async {
        if let lastFetchedAt, clock().timeIntervalSince(lastFetchedAt) < ttl {
            return
        }
        await refresh()
    }

    private func refresh() async {
        // Inflight Task coalescing — second concurrent caller awaits the
        // same Task value rather than no-op'ing out, which under the prior
        // `isLoading` guard caused the second caller to return with stale
        // / empty state while the first was still mid-fetch.
        if let inflight {
            _ = try? await inflight.value
            return
        }
        let task = Task<[SlackChannel], Error> {
            try await provider.fetchAccessibleChannels()
        }
        inflight = task
        defer { inflight = nil }
        do {
            let fetched = try await task.value
            channels = fetched
            lastFetchedAt = clock()
            error = nil
        } catch {
            self.error = error.localizedDescription
            // Preserve previously-fetched `channels` — transient blip
            // should not blank the picker.
        }
    }
}
