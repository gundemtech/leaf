//
//  GitHubScopesService.swift
//  LeafCore
//
//  Phase Track-3 D2 — Task 12. Concrete actor backing the
//  `GitHubScopesChecking` protocol that warm/cold collectors and the UI
//  re-auth banner depend on.
//
//  Responsibilities:
//   - Read `integrations.scope` for `provider = github` (space-separated
//     OAuth scopes per GitHub's `X-OAuth-Scopes` convention).
//   - Cache parsed `Set<String>` behind actor isolation (read fan-out from
//     warm/cold collectors must not race the lazy load).
//   - Expose membership predicates (`has`) and gap derivations (`missing`
//     for blocking required-core; `missingOptional` informational only).
//
//  Why an actor and not a struct: warm/cold collector ticks both reach for
//  the same scope cache, plus a future SwiftUI Observable wrapper (Task 16)
//  reads on MainActor — single source-of-truth needs ordered mutation.
//
//  Why two init paths:
//   - `init(grantedOverride:)` — synchronous test injection. Refresh is
//     a no-op (override is the source of truth, no DB to read).
//   - `init(database:)` — production path. Lazy load on first read so
//     `Agent.main()` boot ordering does not depend on integrations row
//     existing yet (user may not have completed OAuth at first launch).
//

import Foundation
import os

private let scopesLogger = Logger(subsystem: "tech.gundem.leaf.core", category: "github-scopes")

public actor GitHubScopesService {
    /// Scopes without which the key feed/state endpoints degrade to
    /// a useless state. The re-auth banner surfaces missing core
    /// immediately as a blocker.
    public static let requiredCore: Set<String> = [
        "repo",
        "read:user",
        "read:org",
        "read:project"
    ]

    /// Scopes that extend coverage, but the MVP ships without them.
    /// The banner mentions them, but doesn't block.
    public static let requiredOptional: Set<String> = [
        "security_events",
        "read:audit_log"
    ]

    /// Sorted union — Device Flow scope param construction (Task 14).
    /// The sort is needed for deterministic test asserts.
    public static func requested() -> [String] {
        Array(requiredCore.union(requiredOptional)).sorted()
    }

    // MARK: - State

    private let database: Database?
    private var cached: Set<String>?

    // MARK: - Init

    /// Test injection. `grantedOverride` — the eternal source of truth for
    /// this instance; `refresh()` no-op.
    public init(grantedOverride: Set<String>) {
        self.database = nil
        self.cached = grantedOverride
    }

    /// Production. Lazy: `integrations.scope` is read on the first query.
    public init(database: Database) {
        self.database = database
        self.cached = nil
    }

    // MARK: - Public API

    /// The current granted-set. The production path reads from the DB on first access
    /// (after refresh — again on the next one).
    public func currentGranted() -> Set<String> {
        if let cached {
            return cached
        }
        let loaded = loadFromDatabase()
        cached = loaded
        return loaded
    }

    /// Scopes from `requiredCore` that are not in granted. Empty == healthy.
    public func missing() -> Set<String> {
        Self.requiredCore.subtracting(currentGranted())
    }

    /// Scopes from `requiredOptional` that are not in granted. Informational —
    /// the caller (UI) renders "Optional features unavailable" but doesn't block.
    public func missingOptional() -> Set<String> {
        Self.requiredOptional.subtracting(currentGranted())
    }

    /// Membership predicate — protocol entry point for warm/cold collectors.
    public func has(_ scope: String) -> Bool {
        currentGranted().contains(scope)
    }

    /// Reset the cache — the next call re-reads `integrations.scope`.
    /// Override-path no-op (override is the truth).
    public func refresh() {
        guard database != nil else { return }
        cached = nil
    }

    // MARK: - Private

    /// Parses `integrations.scope` for the `github` provider.
    /// Disconnect / DB-read failure → empty set (caller treats as
    /// "not granted" → skip gated endpoints, surface re-auth banner).
    private func loadFromDatabase() -> Set<String> {
        guard let database else { return [] }
        do {
            guard let record = try database.readIntegration(provider: .github) else {
                return []
            }
            return Self.parseScopeString(record.scope)
        } catch {
            scopesLogger.warning(
                "Failed to read github integration row: \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    /// GitHub's OAuth token-exchange JSON response returns the granted scope
    /// as a **comma-separated** string (e.g. `"repo,read:user,read:org"`),
    /// while the legacy `X-OAuth-Scopes` HTTP header form is space-separated.
    /// Split on both — multi-space tolerant; trim per token; empty / whitespace-
    /// only → empty set. Without comma support, every token-exchange response
    /// would parse to a single weird token and surface as "all scopes missing".
    static func parseScopeString(_ raw: String) -> Set<String> {
        let parts = raw
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { String($0) }
            .filter { !$0.isEmpty }
        return Set(parts)
    }
}

extension GitHubScopesService: GitHubScopesChecking {}
