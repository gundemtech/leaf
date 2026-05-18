//
//  CrossPostLogReader.swift
//  LeafCore
//
//  Track 5 / S7 C.7 — @Observable cache for cross_post_log Supabase rows.
//
//  Sits between the UI (LeafMessageCard status chips) and SupabaseClient,
//  providing:
//    • Batch fetch for a set of message IDs (only missing IDs are fetched —
//      already-cached IDs are served from the in-memory cache).
//    • Realtime push absorption (Realtime POSTGRES_CHANGES can deliver new
//      rows; caller passes them to absorbRealtimePush(_:) for zero-refetch
//      cache updates).
//    • Per-message-ID lookup via crossPosts(for:).
//    • Cache invalidation for deleted messages.
//
//  Design: @MainActor because all @Observable state is read from the main
//  actor in SwiftUI. SupabaseClient is an actor (off main) — calls bridge with
//  `await`. State transitions are always driven by this actor's methods, so no
//  concurrent mutation hazard.
//

import Foundation
import Observation

@MainActor
@Observable
public final class CrossPostLogReader {

    // MARK: - State

    public enum State: Equatable {
        case idle
        case loading
        case loaded(byMessageID: [String: [CrossPostLogRow]])
        case error(String)

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle):                 return true
            case (.loading, .loading):           return true
            case (.loaded(let l), .loaded(let r)): return l == r
            case (.error(let l), .error(let r)): return l == r
            default:                             return false
            }
        }
    }

    // MARK: - Published state

    public private(set) var state: State = .idle

    // MARK: - Dependencies

    private let supabase: SupabaseClient

    // MARK: - Cache

    /// In-memory map from message_id → sorted rows for that message.
    /// Nil entry = ID never requested. Empty-array entry = ID was requested
    /// but had no cross-posts on the server.
    private var cache: [String: [CrossPostLogRow]] = [:]

    // MARK: - Init

    public init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    // MARK: - Public API

    /// Batch-fetch cross-post entries for the given message IDs.
    ///
    /// Cache lookup first: IDs already in the cache are served without
    /// a network call. Only IDs absent from the cache are fetched.
    ///
    /// Empty input → no-op (no network, state unchanged).
    ///
    /// On success: state → `.loaded(byMessageID: cache)`.
    /// On failure: state → `.error(description)`.
    public func loadForMessages(_ messageIDs: [String]) async {
        let missing = messageIDs.filter { cache[$0] == nil }
        guard !missing.isEmpty else {
            // All requested IDs are already cached (or input was empty).
            // Emit .loaded only if the cache is non-empty so the UI can read
            // the state. If the cache is also empty (input was []) we leave
            // state as .idle.
            if !cache.isEmpty {
                state = .loaded(byMessageID: cache)
            }
            return
        }

        state = .loading
        do {
            let rows = try await supabase.fetchCrossPostLog(messageIDs: missing)
            // Group fetched rows by messageID.
            let grouped = Dictionary(grouping: rows, by: \.messageID)
            // Cache all requested IDs — even those with no rows (empty array
            // means "server has no cross-posts for this message", which is
            // a valid cacheable answer so we don't re-fetch on next call).
            for id in missing {
                cache[id] = grouped[id] ?? []
            }
            state = .loaded(byMessageID: cache)
        } catch {
            state = .error(String(describing: error))
        }
    }

    /// Returns cached cross-post rows for a single message_id.
    ///
    /// Returns an empty array when:
    ///   • The ID has never been requested (not yet cached), or
    ///   • The server confirmed there are no cross-posts for this message.
    ///
    /// Callers should call `loadForMessages` before relying on this value
    /// if the ID may not yet be cached.
    public func crossPosts(for messageID: String) -> [CrossPostLogRow] {
        cache[messageID] ?? []
    }

    /// Inserts or replaces a row arriving from a Realtime POSTGRES_CHANGES push.
    ///
    /// Replacement logic: an existing row in the cache for the same messageID
    /// is removed if it has the same `(platform, externalRef)` composite key —
    /// ensuring no duplicate "Slack #leaf-architecture" chips appear when a
    /// status update arrives for an already-displayed cross-post.
    ///
    /// Always transitions state to `.loaded(byMessageID: cache)`.
    public func absorbRealtimePush(_ row: CrossPostLogRow) {
        var existing = cache[row.messageID] ?? []
        // Remove any prior row with the same (platform, externalRef) composite.
        existing.removeAll { $0.platform == row.platform && $0.externalRef == row.externalRef }
        existing.append(row)
        cache[row.messageID] = existing
        state = .loaded(byMessageID: cache)
    }

    /// Removes all cached entries for a message_id (e.g. after the DM is deleted).
    ///
    /// If the cache becomes empty, state reverts to `.idle`.
    /// Otherwise state stays `.loaded(byMessageID: cache)`.
    public func invalidate(messageID: String) {
        cache.removeValue(forKey: messageID)
        state = cache.isEmpty ? .idle : .loaded(byMessageID: cache)
    }
}
