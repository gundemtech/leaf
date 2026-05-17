//
//  ConnectionsView+SlackScopes.swift
//  Slack OAuth scope diagnostics: parallels GitHubScopes section — badge
//  matrix + per-scope warnings + Re-authorize CTA + integrations-row read.
//

import SwiftUI
import LeafCore

extension ConnectionsView {

    // MARK: - Slack Scopes section (Phase Track-3 D3 / Task 20)

    /// Mirrors `shouldShowScopesSection` for Slack — section renders when
    /// `slackScopes.state` is either `.connected` (informational matrix, no
    /// banners) or `.connectedScopeOutdated` (warning banners + Re-authorize
    /// CTA). Hidden in `.unknown` / `.notConfigured`.
    var shouldShowSlackScopesSection: Bool {
        switch slackScopes.state {
        case .connected, .connectedScopeOutdated:
            return true
        case .unknown, .notConfigured:
            return false
        }
    }

    var currentGrantedSlack: Set<String> {
        grantedSlackScopes
    }

    var missingSlackCore: Set<String> {
        SlackScopesService.requiredCore.subtracting(currentGrantedSlack)
    }

    var missingSlackOptional: Set<String> {
        SlackScopesService.requiredOptional.subtracting(currentGrantedSlack)
    }

    var allRequestedSlackScopes: [String] {
        Array(SlackScopesService.requiredCore
            .union(SlackScopesService.requiredOptional)).sorted()
    }

    @ViewBuilder
    var slackScopesSection: some View {
        LeafSection(
            title: "Scopes",
            description: "Slack OAuth scopes Leaf uses to read your activity."
        ) {
            LeafCard(variant: .raised, padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.md) {
                    slackBadgeMatrix
                    if !missingSlackCore.isEmpty {
                        ForEach(Array(missingSlackCore).sorted(), id: \.self) { scope in
                            LeafBanner(
                                tone: .warning,
                                title: scope,
                                description: Self.slackScopeExplainer[scope]
                                    ?? "Required for Slack integration."
                            )
                        }
                    }
                    if !missingSlackOptional.isEmpty {
                        Text("Recommended scopes not granted: \(missingSlackOptional.sorted().joined(separator: ", "))")
                            .font(LeafType.body.small)
                            .foregroundStyle(LeafColor.text.tertiary)
                    }
                    if !missingSlackCore.isEmpty || !missingSlackOptional.isEmpty {
                        LeafButton(
                            "Re-authorize Slack",
                            variant: .primary,
                            size: .md,
                            action: {
                                Task { await slackOAuth.connect() }
                            }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    var slackBadgeMatrix: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 110), spacing: LeafSpace.xs, alignment: .leading)],
            alignment: .leading,
            spacing: LeafSpace.xs
        ) {
            ForEach(allRequestedSlackScopes, id: \.self) { scope in
                let granted = currentGrantedSlack.contains(scope)
                let core = SlackScopesService.requiredCore.contains(scope)
                LeafBadge(
                    text: scope,
                    variant: granted ? .accent : .neutral
                )
                .accessibilityLabel(badgeAccessibilityLabel(scope: scope, granted: granted, core: core))
            }
        }
    }

    /// Mirrors `refreshGrantedGitHubScopes` — reads `integrations.scope` for
    /// `provider = slack` synchronously on main thread (single-row query).
    func refreshGrantedSlackScopes() {
        grantedSlackScopes = Self.readGrantedSlackScopes()
    }

    nonisolated static func readGrantedSlackScopes() -> Set<String> {
        do {
            let db = try Database.openForRead(
                at: DatabasePath.defaultURL(),
                config: githubScopesDatabaseConfig(),
                encryption: githubScopesDatabaseEncryption()
            )
            guard let record = try db.readIntegration(provider: .slack) else {
                return []
            }
            return parseGitHubScopeString(record.scope)
        } catch {
            return []
        }
    }
}
