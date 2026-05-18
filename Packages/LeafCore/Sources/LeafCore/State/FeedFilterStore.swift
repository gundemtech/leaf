//
//  FeedFilterStore.swift
//  LeafCore
//
//  Track 5 / S7 G.1 — @Observable state holder for Team feed filter chips.
//  Manages per-workspace persisted selection with the mutex .all rule
//  (spec §4.5). Wired into TeamView via .environment(feedFilterStore).
//

import Foundation
import Observation

/// @MainActor @Observable store for the Team feed's active filter chip set.
///
/// Mutex rule (spec §4.5):
///  • `.all` is mutually exclusive with every other filter.
///  • Selecting `.all` collapses the set to `[.all]`.
///  • Selecting any non-`.all` filter removes `.all` from the set.
///  • Deselecting the last remaining non-`.all` filter restores `[.all]`.
///
/// Persistence: each workspace's selection is stored as JSON-encoded
/// `[FeedFilter]` under a per-workspace UserDefaults key. Corrupt or missing
/// data silently falls back to `[.all]`.
@MainActor
@Observable
public final class FeedFilterStore {

    // MARK: - State

    /// Currently active filter set. Always non-empty; contains `.all` when
    /// no specific filters are chosen.
    ///
    /// Direct mutation is allowed so `@Bindable` wrappers can drive
    /// `LeafFilterChips` which writes back the full new selection via a
    /// `Binding<Set<FeedFilter>>` setter. Callers should prefer `toggle(_:)`
    /// for the mutex `.all` invariant; direct assignment (e.g., from a chip
    /// binding) is safe because `LeafFilterChips` enforces the same rule internally.
    ///
    /// Note: @Observable macro does not support property observers (didSet/willSet)
    /// on tracked properties. Persistence is triggered explicitly by all mutating
    /// methods (`toggle`, `clearAll`, `applySelection`). The `selected` setter is
    /// used exclusively by the binding in `FeedFilterChipsBindable` which routes
    /// through `applySelection(_:)` instead of direct assignment to ensure persist().
    public var selected: Set<FeedFilter> = [.all]

    /// Apply a new selection (from a `Binding` write-back) and persist.
    /// Use this instead of assigning `selected` directly.
    public func applySelection(_ newSelection: Set<FeedFilter>) {
        selected = newSelection.isEmpty ? [.all] : newSelection
        persist()
    }

    // MARK: - Private

    private let userDefaults: UserDefaults
    private var currentWorkspaceID: String?

    // MARK: - Init

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    // MARK: - Public API

    /// Load the persisted selection for `workspaceID`. Call this when the
    /// active workspace changes (e.g., in `.task(id: activeWorkspaceID)`).
    /// Falls back to `[.all]` when no persisted data exists or decoding fails.
    public func loadForWorkspace(_ workspaceID: String) {
        currentWorkspaceID = workspaceID
        let key = Self.userDefaultsKey(workspaceID: workspaceID)
        if let data = userDefaults.data(forKey: key),
           let restored = try? JSONDecoder().decode([FeedFilter].self, from: data),
           !restored.isEmpty {
            selected = Set(restored)
        } else {
            selected = [.all]
        }
    }

    /// Toggle a filter, applying the mutex `.all` rule.
    public func toggle(_ f: FeedFilter) {
        if f.isExclusive {
            // Selecting .all collapses every other selection.
            selected = [.all]
        } else {
            // Any other filter: remove .all first.
            selected.remove(.all)
            if selected.contains(f) {
                selected.remove(f)
                // Restore .all if set would become empty.
                if selected.isEmpty { selected = [.all] }
            } else {
                selected.insert(f)
            }
        }
        persist()
    }

    /// Collapse selection back to `[.all]` and persist.
    public func clearAll() {
        selected = [.all]
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        guard let wid = currentWorkspaceID else { return }
        let key = Self.userDefaultsKey(workspaceID: wid)
        if let data = try? JSONEncoder().encode(Array(selected)) {
            userDefaults.set(data, forKey: key)
        }
    }

    /// Stable UserDefaults key scoped to a workspace ID.
    public static func userDefaultsKey(workspaceID: String) -> String {
        "leaf.feedFilters.\(workspaceID)"
    }
}
