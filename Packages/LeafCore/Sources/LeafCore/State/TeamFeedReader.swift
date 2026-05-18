//
//  TeamFeedReader.swift
//  LeafCore
//
//  Track 5 / S7 C.1-C.6 — @Observable reader for the unified Team feed.
//  Wraps TeamFeedQueryService and exposes paginated FeedItem state to SwiftUI
//  via the @Observable macro.
//
//  Implementation phases:
//    • C.1/C.2: FeedItem enum lives in LeafCore/TeamFeedItem.swift.
//    • C.4: loadInitial / refresh full implementations.
//    • C.5: applyGrouping full implementation (15-min window, 5+ threshold,
//           same sender+source). OQ-12 resolved to 15 minutes.
//    • C.6: loadOlder (cursor-based back-pagination, append-below).
//
//  Moved from Leaf app target → LeafCore so the business logic is testable from
//  LeafCoreTests without requiring an Xcode test target for the app bundle.
//
//  Design note: TeamFeedReader is @MainActor because all @Observable state must
//  be read from the main actor in SwiftUI. The underlying TeamFeedQueryService is
//  an actor (off main) — calls are bridged with `await`.
//

import Foundation
import Observation

@MainActor
@Observable
public final class TeamFeedReader {

    // MARK: - Types

    public enum State: Equatable {
        case loading
        case loaded(items: [FeedItem], hasMore: Bool)
        case error(String)

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading):
                return true
            case (.loaded(let li, let lm), .loaded(let ri, let rm)):
                return li == ri && lm == rm
            case (.error(let l), .error(let r)):
                return l == r
            default:
                return false
            }
        }
    }

    // MARK: - State

    public private(set) var state: State = .loading

    /// S7 Stage 6 fix B-I1 — last error from `loadOlder` surfaced as a side
    /// channel so the UI can show a banner without wiping the current page of
    /// loaded items. Matches the S4 `DirectMessageInboxReader.lastTickError`
    /// pattern: state stays `.loaded`, the user keeps the rows they already
    /// saw, and the banner reflects the transient pagination failure.
    public private(set) var lastLoadOlderError: String?

    /// S7 Stage 6 fix B-I5 — refresh-in-flight indicator surfaced as a side
    /// channel. When `loadInitial` is called from a `.loaded` state (filter
    /// toggle, workspace switch where prior state is still visible,
    /// pull-to-refresh), the reader keeps the current items rendered and
    /// flips `isRefreshing = true` for the fetch duration. The UI overlays a
    /// subtle progress indicator instead of flashing through `.loading` (which
    /// would wipe the feed for tens of ms each time a chip toggles).
    public private(set) var isRefreshing: Bool = false

    // MARK: - Dependencies

    private let queryService: TeamFeedQueryService
    /// Resolves sender pubkey hex → TeamMember for grouped item construction.
    /// Returns nil when the member cannot be found (graceful fallback: individual rows).
    private let memberResolver: (String) -> TeamMember?

    // MARK: - Constants

    /// Grouping window: 15 minutes in milliseconds (OQ-12 resolved to 15m).
    private static let groupingWindowMs: Int64 = 15 * 60 * 1_000
    /// Minimum run length to collapse into a `.grouped` item (spec §7.1).
    private static let groupingThreshold: Int = 5

    // MARK: - Init

    /// - Parameters:
    ///   - queryService:    DB-backed fetch actor (LeafCore).
    ///   - memberResolver:  Closure mapping `senderPubkeyHex` → `TeamMember?`.
    ///                      Called on the main actor inside `applyGrouping`.
    ///                      Return nil to fall back to individual rows for that burst.
    public init(
        queryService: TeamFeedQueryService,
        memberResolver: @escaping (String) -> TeamMember? = { _ in nil }
    ) {
        self.queryService = queryService
        self.memberResolver = memberResolver
    }

    // MARK: - Public API

    /// Load the initial page of feed items.
    ///
    /// Cold first call (state == .loading or .error): transitions to .loading
    /// for the fetch duration, then to .loaded or .error.
    ///
    /// Warm refresh (state == .loaded): keeps the current items rendered and
    /// flips `isRefreshing` true for the fetch duration, then replaces items
    /// atomically (or transitions to .error on failure — preserving items via
    /// .loaded would be inconsistent with the user-perceived "I asked for a
    /// fresh page and it failed"). S7 Stage 6 fix B-I5.
    public func loadInitial(
        workspaceID: String,
        filters: Set<FeedFilter>,
        selfPubkeyHex: String,
        limit: Int = 50
    ) async {
        if case .loaded = state {
            isRefreshing = true
        } else {
            state = .loading
        }
        defer { isRefreshing = false }

        do {
            let raw = try await queryService.fetch(
                workspaceID: workspaceID,
                filters: filters,
                limit: limit,
                before: nil,
                selfPubkeyHex: selfPubkeyHex
            )
            let grouped = applyGrouping(raw)
            state = .loaded(items: grouped, hasMore: raw.count == limit)
        } catch {
            state = .error(String(describing: error))
        }
    }

    /// Refresh (replace) the current page. Equivalent to `loadInitial` — full
    /// page re-fetch from the head of the feed.
    public func refresh(
        workspaceID: String,
        filters: Set<FeedFilter>,
        selfPubkeyHex: String,
        limit: Int = 50
    ) async {
        await loadInitial(
            workspaceID: workspaceID,
            filters: filters,
            selfPubkeyHex: selfPubkeyHex,
            limit: limit
        )
    }

    /// Load an older page (append-below). Requires `before` timestamp from the
    /// oldest visible item. No-ops when not in `.loaded` state.
    public func loadOlder(
        workspaceID: String,
        filters: Set<FeedFilter>,
        selfPubkeyHex: String,
        before: Int64,
        limit: Int = 50
    ) async {
        guard case .loaded(let current, _) = state else { return }
        do {
            let raw = try await queryService.fetch(
                workspaceID: workspaceID,
                filters: filters,
                limit: limit,
                before: before,
                selfPubkeyHex: selfPubkeyHex
            )
            let older = applyGrouping(raw)
            state = .loaded(items: current + older, hasMore: raw.count == limit)
            lastLoadOlderError = nil
        } catch {
            // S7 Stage 6 fix B-I1 — preserve currently-visible items on
            // pagination failure. The previous behaviour transitioned state
            // to .error which wiped the entire feed from the UI — a flaky
            // network during scroll would dump the user from a working feed
            // into an empty error banner. Now: state stays .loaded with
            // hasMore=false, lastLoadOlderError carries the surface message
            // for the UI to render as a non-blocking banner.
            state = .loaded(items: current, hasMore: false)
            lastLoadOlderError = String(describing: error)
        }
    }

    // MARK: - Grouping (spec §7.1)

    /// Collapses consecutive same-sender + same-source team events within a
    /// 15-minute window (OQ-12) into a single `.grouped` item when the burst
    /// reaches the threshold of 5+ events.
    ///
    /// Algorithm (items arrive in DESC order — newest first):
    ///   1. Walk items left-to-right (i.e., newest → oldest within a burst).
    ///   2. A new item extends the current burst when:
    ///        • It is a `.teamEvent` (DMs are never grouped)
    ///        • `source` matches burst head's source
    ///        • `senderPubkeyHex` matches burst head's sender
    ///        • |head.eventTsMs − row.eventTsMs| ≤ 15 min
    ///   3. Any mismatch → flush current burst, start new burst.
    ///   4. Flush: if burst.count ≥ 5, emit `.grouped`; else emit individual rows.
    ///   5. Unresolvable sender → fall back to individual rows (no crash).
    public func applyGrouping(_ items: [FeedItem]) -> [FeedItem] {
        var result: [FeedItem] = []
        // Accumulated same-sender/source burst in DESC order (head = newest).
        var burst: [TeamEventMirrorRow] = []

        func flush() {
            guard !burst.isEmpty else { return }
            defer { burst = [] }

            guard burst.count >= Self.groupingThreshold else {
                // Below threshold → individual rows.
                result.append(contentsOf: burst.map { .teamEvent($0) })
                return
            }

            // burst[0] = newest (spanEnd), burst[last] = oldest (spanStart)
            let newest = burst.first!
            let oldest = burst.last!

            guard let sender = memberResolver(oldest.senderPubkeyHex) else {
                // Cannot resolve member → fall back to individual rows.
                result.append(contentsOf: burst.map { .teamEvent($0) })
                return
            }

            result.append(.grouped(
                kind: oldest.source,
                sender: sender,
                count: burst.count,
                spanStartMs: oldest.eventTsMs,
                spanEndMs: newest.eventTsMs,
                items: burst
            ))
        }

        for item in items {
            switch item {
            case .teamEvent(let row):
                if let head = burst.first,
                   head.source == row.source,
                   head.senderPubkeyHex == row.senderPubkeyHex,
                   abs(head.eventTsMs - row.eventTsMs) <= Self.groupingWindowMs {
                    burst.append(row)
                } else {
                    flush()
                    burst = [row]
                }
            case .directMessage:
                // DMs break any open burst.
                flush()
                result.append(item)
            case .grouped:
                // Pass through (shouldn't arrive from raw query, but handle gracefully).
                flush()
                result.append(item)
            }
        }
        flush()
        return result
    }
}
