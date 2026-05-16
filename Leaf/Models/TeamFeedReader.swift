//
//  TeamFeedReader.swift
//  Leaf
//
//  Track 5 / S7 C.1 + C.2 — @Observable skeleton for the unified Team feed.
//  Wraps TeamFeedQueryService (LeafCore) and exposes paginated FeedItem state
//  to SwiftUI via the @Observable macro.
//
//  Phase C implementation:
//    • C.1/C.2  (this file): FeedItem enum lives in LeafCore/TeamFeedItem.swift;
//               this reader re-exports it via `typealias FeedItem = LeafCore.FeedItem`
//               and holds state + stub methods.
//    • C.4: loadInitial / refresh full implementations.
//    • C.5: applyGrouping full implementation (5-min window, same sender+source).
//    • C.6: loadOlder (cursor-based back-pagination).
//
//  Design note: TeamFeedReader is @MainActor because all @Observable state must
//  be read from the main actor in SwiftUI. The underlying TeamFeedQueryService is
//  an actor (off main) — calls are bridged with `await`.
//

import Foundation
import Observation
import LeafCore

@MainActor
@Observable
final class TeamFeedReader {

    // MARK: - Types

    typealias FeedItem = LeafCore.FeedItem

    enum State: Equatable {
        case loading
        case loaded(items: [FeedItem], hasMore: Bool)
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
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

    private(set) var state: State = .loading

    // MARK: - Dependencies

    private let queryService: TeamFeedQueryService

    // C.4 will add: activeWorkspaceStore, selfPubkeyProvider
    // C.5 will add: groupingThresholdMs (default 5 * 60 * 1000)

    // MARK: - Init

    init(queryService: TeamFeedQueryService) {
        self.queryService = queryService
    }

    // MARK: - Public API (stubs; full implementations in C.4-C.6)

    /// Load the initial page of feed items. Sets state → .loaded or .error.
    /// Full implementation in C.4.
    func loadInitial(
        workspaceID: String,
        filters: Set<FeedFilter>,
        selfPubkeyHex: String,
        limit: Int = 50
    ) async {
        state = .loading
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

    /// Refresh (replace) the current page. Sets state → .loaded or .error.
    /// Full implementation in C.4 (will diff + animate).
    func refresh(
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

    /// Load an older page (append-below). Requires `before` timestamp from oldest
    /// visible item. Full implementation in C.6.
    func loadOlder(
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
        } catch {
            state = .error(String(describing: error))
        }
    }

    /// Collapse consecutive same-sender + same-source team events within a 5-min
    /// window into a single `.grouped` item. Full grouping logic in C.5.
    /// Currently returns items unchanged (identity stub).
    func applyGrouping(_ items: [FeedItem]) -> [FeedItem] {
        // C.5: implement 5-min window same-sender same-source grouping
        return items
    }
}
