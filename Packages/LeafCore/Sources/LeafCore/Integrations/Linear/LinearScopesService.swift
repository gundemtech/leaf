//
//  LinearScopesService.swift
//  LeafCore
//
//  Track 5 / S6 T5 — actor backing the cross-post UI scope-gate check.
//  Symmetric with SlackScopesService (Track 3 D3 precedent).
//
//  Responsibilities:
//   - Read `integrations.scope` for `provider = linear` (Linear OAuth returns
//     scopes as comma-separated string per Linear docs).
//   - Cache parsed `Set<String>` behind actor isolation.
//   - Expose `has` predicate + `missing` / `missingOptional` gap derivations.
//
//  Scope policy (A3 brainstorm — narrower than full `write`):
//   - requiredCore = ["read"]      — baseline for Linear collector
//   - requiredOptional = ["issues:create"]  — S6 cross-post (issueCreate mutation)
//
//  Future `comments:create` for Track 6 cross-post-as-comment (M13 carry-over).
//

import Foundation
import os

private let scopesLogger = Logger(subsystem: "tech.gundem.leaf.core", category: "linear-scopes")

public actor LinearScopesService {
    /// Scopes without which the Linear baseline collector cannot function.
    public static let requiredCore: Set<String> = ["read"]

    /// Scopes that extend S6 cross-post coverage (issueCreate mutation).
    /// The banner mentions them; it does not block the collector flow.
    public static let requiredOptional: Set<String> = ["issues:create"]

    /// Sorted union — OAuth authorize URL scope param construction.
    /// Sort is needed for deterministic test asserts.
    public static func requested() -> [String] {
        Array(requiredCore.union(requiredOptional)).sorted()
    }

    // MARK: - State

    private let database: Database?
    private var cached: Set<String>?

    // MARK: - Init

    /// Test injection. `grantedOverride` — eternal source of truth for the instance;
    /// `refresh()` no-op.
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

    /// Current granted-set. Production path reads from the DB on first access.
    public func currentGranted() -> Set<String> {
        if let cached { return cached }
        let loaded = loadFromDatabase()
        cached = loaded
        return loaded
    }

    /// Scopes from `requiredCore` that are missing from granted. Empty == healthy.
    public func missing() -> Set<String> {
        Self.requiredCore.subtracting(currentGranted())
    }

    /// Scopes from `requiredOptional` that are missing from granted. Informational —
    /// caller (UI) renders an inline re-auth banner in the Send sheet.
    public func missingOptional() -> Set<String> {
        Self.requiredOptional.subtracting(currentGranted())
    }

    /// Membership predicate — protocol entry point for the cross-post UI.
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

    /// Parses `integrations.scope` for the `linear` provider.
    /// Disconnect / DB-read failure → empty set (caller treats as
    /// "not granted" → skip gated endpoints, surface re-auth banner).
    private func loadFromDatabase() -> Set<String> {
        guard let database else { return [] }
        do {
            guard let record = try database.readIntegration(provider: .linear) else {
                return []
            }
            return Self.parseScopeString(record.scope)
        } catch {
            scopesLogger.warning(
                "Failed to read linear integration row: \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    /// Linear OAuth response returns the granted scopes as comma-separated
    /// string. Split on both commas AND whitespace (multi-space tolerant;
    /// trim per token; empty → empty set) for forward-compat.
    public static func parseScopeString(_ raw: String) -> Set<String> {
        let parts = raw
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { String($0) }
            .filter { !$0.isEmpty }
        return Set(parts)
    }
}

extension LinearScopesService: LinearScopesChecking {}
