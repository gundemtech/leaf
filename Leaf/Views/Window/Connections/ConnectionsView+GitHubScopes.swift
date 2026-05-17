//
//  ConnectionsView+GitHubScopes.swift
//  GitHub OAuth scope diagnostics: badge matrix (granted vs missing-core vs
//  missing-optional) + per-scope warning banners + Re-authorize CTA + the
//  synchronous integrations-row read that backs `grantedGitHubScopes`.
//

import SwiftUI
import LeafCore
#if LEAF_PROD
import LeafCorePrivate
#endif

extension ConnectionsView {

    // MARK: - GitHub Scopes section (Task 19)

    /// Render Scopes section under the GitHub block when the connection is
    /// in either `.connected` (informational — granted-only badges, no warnings,
    /// no CTA) OR `.connectedScopeOutdated` (full layout — warnings + CTA).
    /// Skipped for `.notConfigured` / `.unknown` (no GitHub connected) and any
    /// non-connected state of the underlying `githubOAuth` flow.
    var shouldShowScopesSection: Bool {
        switch scopesReader.state {
        case .connected, .connectedScopeOutdated:
            return true
        case .unknown, .notConfigured:
            return false
        }
    }

    /// Granted scopes intersected with `requested = requiredCore ∪ requiredOptional`.
    /// Used to render the badge matrix. Scopes outside the requested set
    /// (legacy grants) are intentionally excluded — the section only documents
    /// what Leaf asks for, not the full token grant.
    var currentGranted: Set<String> {
        grantedGitHubScopes
    }

    /// Required-core scopes that are not in `currentGranted`. These render
    /// as red-tone badges + per-scope LeafBanner.warning explainers.
    var missingCore: Set<String> {
        GitHubScopesService.requiredCore.subtracting(currentGranted)
    }

    /// Required-optional scopes that are not in `currentGranted`. These
    /// render as a single subtle hint line (no per-scope banner — they're
    /// recommended, not blocking).
    var missingOptional: Set<String> {
        GitHubScopesService.requiredOptional.subtracting(currentGranted)
    }

    /// All scopes Leaf asks for, sorted for stable badge order.
    var allRequestedScopes: [String] {
        Array(GitHubScopesService.requiredCore.union(GitHubScopesService.requiredOptional)).sorted()
    }

    @ViewBuilder
    var scopesSection: some View {
        LeafSection(
            title: "Scopes",
            description: "GitHub OAuth scopes Leaf uses to read your activity."
        ) {
            LeafCard(variant: .raised, padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.md) {
                    badgeMatrix
                    if !missingCore.isEmpty {
                        ForEach(Array(missingCore).sorted(), id: \.self) { scope in
                            LeafBanner(
                                tone: .warning,
                                title: scope,
                                description: Self.scopeExplainer[scope]
                                    ?? "Required for GitHub integration."
                            )
                        }
                    }
                    if !missingOptional.isEmpty {
                        Text("Recommended scopes not granted: \(missingOptional.sorted().joined(separator: ", "))")
                            .font(LeafType.body.small)
                            .foregroundStyle(LeafColor.text.tertiary)
                    }
                    if !missingCore.isEmpty || !missingOptional.isEmpty {
                        LeafButton(
                            "Re-authorize GitHub",
                            variant: .primary,
                            size: .md,
                            action: {
                                Task {
                                    await githubOAuth.connect(
                                        scopes: GitHubScopesService.requested()
                                    )
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    /// Granted/missing badge grid. Wraps via LazyVGrid `.adaptive` because
    /// the codebase doesn't ship a FlowLayout primitive and a plain HStack
    /// would clip on narrow Connections pane widths. Scope tokens are short
    /// (`repo`, `read:org`, `security_events`) so an adaptive minimum of 110pt
    /// fits 2-3 per row at typical pane widths without truncation.
    @ViewBuilder
    var badgeMatrix: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 110), spacing: LeafSpace.xs, alignment: .leading)],
            alignment: .leading,
            spacing: LeafSpace.xs
        ) {
            ForEach(allRequestedScopes, id: \.self) { scope in
                let granted = currentGranted.contains(scope)
                let core = GitHubScopesService.requiredCore.contains(scope)
                // LeafBadge ships only `.neutral / .accent / .numeric` — no
                // `.success / .danger` variant in the substrate. Map intent:
                // granted → `.accent` (positive emphasis); missing-core +
                // missing-optional → `.neutral` (the per-scope LeafBanner.warning
                // below carries the criticality cue, so the badge stays calm).
                LeafBadge(
                    text: scope,
                    variant: granted ? .accent : .neutral
                )
                .accessibilityLabel(badgeAccessibilityLabel(scope: scope, granted: granted, core: core))
            }
        }
    }

    func badgeAccessibilityLabel(scope: String, granted: Bool, core: Bool) -> String {
        if granted {
            return "\(scope), granted"
        }
        return core ? "\(scope), missing required scope" : "\(scope), missing recommended scope"
    }

    /// Reads `integrations.scope` for `provider = github` and parses the
    /// space-separated token list into `grantedGitHubScopes`. Mirrors
    /// `GitHubScopesService.parseScopeString` semantics exactly. Failure path
    /// (no integration row, DB read error) → empty set, which makes the
    /// section render as "all missing" rather than crash. Synchronous because
    /// `Database.readIntegration` is a single-row query and Connections is
    /// already main-thread; we trade trivial latency for an inline path that
    /// avoids a parallel async observable for the same data the reader
    /// already polls.
    func refreshGrantedGitHubScopes() {
        let parsed = Self.readGrantedGitHubScopes()
        grantedGitHubScopes = parsed
    }

    /// Open the canonical app DB (same defaults as `GitHubOAuthService`),
    /// read the GitHub integration row, parse `scope`. Returns empty set on
    /// any failure. `static` so closure captures don't bind to `self`.
    nonisolated static func readGrantedGitHubScopes() -> Set<String> {
        do {
            let db = try Database.openForRead(
                at: DatabasePath.defaultURL(),
                config: githubScopesDatabaseConfig(),
                encryption: githubScopesDatabaseEncryption()
            )
            guard let record = try db.readIntegration(provider: .github) else {
                return []
            }
            return parseGitHubScopeString(record.scope)
        } catch {
            return []
        }
    }

    nonisolated static func githubScopesDatabaseConfig() -> DatabaseConfig {
        #if LEAF_PROD
        return ProdConfigs.database
        #else
        return .weakDefaults
        #endif
    }

    nonisolated static func githubScopesDatabaseEncryption() -> EncryptionOptions? {
        #if LEAF_PROD
        return EncryptionOptions(
            keyProvider: .callback { @Sendable in
                try FileKeyStore.fetchOrCreate()
            },
            preKeyPragmas: ProdConfigs.sqlcipherPragmasPreKey,
            postKeyPragmas: ProdConfigs.sqlcipherPragmasPostKey
        )
        #else
        return nil
        #endif
    }

    /// Inline copy of `GitHubScopesService.parseScopeString`. Kept local to
    /// avoid a public API expansion just for this view; the LeafCore one is
    /// `internal static` so unreachable from the app target. Splits on both
    /// commas and whitespace because GitHub's token-exchange response uses
    /// comma-separated scope strings, while the legacy `X-OAuth-Scopes`
    /// header form is space-separated.
    nonisolated static func parseGitHubScopeString(_ raw: String?) -> Set<String> {
        guard let raw else { return [] }
        let parts = raw
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { String($0) }
            .filter { !$0.isEmpty }
        return Set(parts)
    }
}
