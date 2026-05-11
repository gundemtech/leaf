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
//     a no-op (override is the source of truth, нет DB к чтению).
//   - `init(database:)` — production path. Lazy load on first read so
//     `Agent.main()` boot ordering does not depend on integrations row
//     existing yet (user may not have completed OAuth at first launch).
//

import Foundation
import os

private let scopesLogger = Logger(subsystem: "tech.gundem.leaf.core", category: "github-scopes")

public actor GitHubScopesService {
    /// Scopes без которых ключевые feed/state endpoints деградируют до
    /// бесполезного состояния. Re-auth banner surface'ит missing core
    /// сразу как блокер.
    public static let requiredCore: Set<String> = [
        "repo",
        "read:user",
        "read:org",
        "read:project"
    ]

    /// Scopes которые расширяют покрытие, но MVP без них ship'ится.
    /// Banner упоминает, но не блокирует.
    public static let requiredOptional: Set<String> = [
        "security_events",
        "read:audit_log"
    ]

    /// Sorted union — Device Flow scope param construction (Task 14).
    /// Sort нужен для deterministic test asserts.
    public static func requested() -> [String] {
        Array(requiredCore.union(requiredOptional)).sorted()
    }

    // MARK: - State

    private let database: Database?
    private var cached: Set<String>?

    // MARK: - Init

    /// Test injection. `grantedOverride` — the eternal source of truth для
    /// этого instance; `refresh()` no-op.
    public init(grantedOverride: Set<String>) {
        self.database = nil
        self.cached = grantedOverride
    }

    /// Production. Lazy: `integrations.scope` читается на первой query.
    public init(database: Database) {
        self.database = database
        self.cached = nil
    }

    // MARK: - Public API

    /// Текущий granted-set. Production path читает из DB при первом обращении
    /// (после refresh — снова при следующем).
    public func currentGranted() -> Set<String> {
        if let cached {
            return cached
        }
        let loaded = loadFromDatabase()
        cached = loaded
        return loaded
    }

    /// Scopes из `requiredCore` которых нет в granted. Empty == healthy.
    public func missing() -> Set<String> {
        Self.requiredCore.subtracting(currentGranted())
    }

    /// Scopes из `requiredOptional` которых нет в granted. Informational —
    /// caller (UI) рендерит "Optional features unavailable" но не блокирует.
    public func missingOptional() -> Set<String> {
        Self.requiredOptional.subtracting(currentGranted())
    }

    /// Membership predicate — protocol entry point для warm/cold collectors.
    public func has(_ scope: String) -> Bool {
        currentGranted().contains(scope)
    }

    /// Сбросить кэш — следующий вызов перечитает `integrations.scope`.
    /// Override-path no-op (override is the truth).
    public func refresh() {
        guard database != nil else { return }
        cached = nil
    }

    // MARK: - Private

    /// Парсит `integrations.scope` для `github` provider'а.
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

    /// GitHub returns space-separated. Multi-space tolerant; trim per token;
    /// empty / whitespace-only → empty set.
    static func parseScopeString(_ raw: String) -> Set<String> {
        let parts = raw
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
            .filter { !$0.isEmpty }
        return Set(parts)
    }
}

extension GitHubScopesService: GitHubScopesChecking {}
