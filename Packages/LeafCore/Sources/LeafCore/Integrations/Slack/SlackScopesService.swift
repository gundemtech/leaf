//
//  SlackScopesService.swift
//  LeafCore
//
//  Phase Track-3 D3 — Task 8. Concrete actor backing the
//  `SlackScopesChecking` protocol that warm/cold collectors and the UI
//  re-auth banner depend on.
//
//  Responsibilities:
//   - Read `integrations.scope` for `provider = slack` (comma-separated
//     OAuth scopes per Slack's `oauth.v2.access` JSON `authed_user.scope` shape).
//   - Cache parsed `Set<String>` behind actor isolation (read fan-out from
//     warm/cold collectors must not race the lazy load).
//   - Expose membership predicates (`has`) and gap derivations (`missing`
//     for blocking required-core; `missingOptional` informational only).
//
//  Why an actor and not a struct: warm/cold collector ticks both reach for
//  the same scope cache, plus a future SwiftUI Observable wrapper reads on
//  MainActor — single source-of-truth needs ordered mutation.
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

private let scopesLogger = Logger(subsystem: "tech.gundem.leaf.core", category: "slack-scopes")

public actor SlackScopesService {
    /// Scopes без которых Slack baseline collector не может функционировать.
    /// Re-auth banner surface'ит missing core сразу как блокер.
    public static let requiredCore: Set<String> = [
        "users:read", "users.profile:read", "search:read",
        "channels:read", "groups:read", "im:read", "mpim:read",
        "channels:history", "groups:history", "im:history", "mpim:history",
        "dnd:read", "files:read",
    ]

    /// Scopes которые расширяют D3 покрытие (reactions / pins / bookmarks /
    /// reminders / chat / stars / canvases / emoji / usergroups).
    /// Banner упоминает, но не блокирует.
    public static let requiredOptional: Set<String> = [
        "reactions:read", "pins:read", "bookmarks:read", "reminders:read",
        "chat:write", "stars:read", "canvases:read", "emoji:read", "usergroups:read",
    ]

    /// Sorted union — OAuth authorize URL scope param construction.
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

    /// Парсит `integrations.scope` для `slack` provider'а.
    /// Disconnect / DB-read failure → empty set (caller treats as
    /// "not granted" → skip gated endpoints, surface re-auth banner).
    private func loadFromDatabase() -> Set<String> {
        guard let database else { return [] }
        do {
            guard let record = try database.readIntegration(provider: .slack) else {
                return []
            }
            return Self.parseScopeString(record.scope)
        } catch {
            scopesLogger.warning(
                "Failed to read slack integration row: \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    /// Slack's `oauth.v2.access` JSON response returns the granted user scopes
    /// in `authed_user.scope` as a **comma-separated** string. Split on both
    /// commas AND whitespace (multi-space tolerant; trim per token; empty
    /// → empty set) for forward-compat with any format variation.
    public static func parseScopeString(_ raw: String) -> Set<String> {
        let parts =
            raw
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { String($0) }
            .filter { !$0.isEmpty }
        return Set(parts)
    }
}

extension SlackScopesService: SlackScopesChecking {}
