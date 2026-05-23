//
//  HomeView.swift
//  Track 8 / Phase 8.2 — Operational console shell. Composition + Zone
//  layout was extracted to `HomeContent.swift` in Track-10 T7 C4 for LOC
//  budget defense (master spec §7.2 gate 6 ≤ 310). Post-Track-10 composition
//  (T2 hero promote + T3 YOU·NOW badge inline + T4 NEEDS YOU rename + T6
//  TEAM·N Zone-3 + T7 YOU'RE ON Zone-4):
//
//    1. RESUME HERO                              (T2, full width)
//    2. TODAY (with inline YOU·NOW state badge)  (T3, full width)
//    3. NEEDS YOU ‖ TEAM·N  (ViewThatFits 2-col) (T4, T6)
//    4. SINCE ‖ YOU'RE ON   (ViewThatFits 2-col) (T5, T7)
//
//  State-machine UX (InsightsReader.State):
//    .loading        → LoadingScaffold with muted shape placeholders.
//    .notConfigured  → Full-page LeafEmptyState + 'Open Connections' CTA.
//    .empty          → Full-page LeafEmptyState (no CTA).
//    .error          → LeafBanner.danger at top + 'Try again' CTA + last-known content.
//    .loaded         → HomeContent (extracted) — 4-zone render.
//
//  NavigationStack destinations live on HomeContent.
//

import LeafCore
import SwiftUI

struct HomeView: View {
    @Environment(InsightsReader.self) private var reader
    @Environment(WindowState.self) private var windowState
    @Environment(GitHubScopesReader.self) private var scopesReader
    @Environment(GitHubOAuthService.self) private var githubOAuth
    @Environment(SlackScopesReader.self) private var slackScopes
    @Environment(SlackOAuthService.self) private var slackOAuth

    /// Session-local dismiss flag for the proactive GitHub re-auth banner.
    /// Persisted across the same launch via UserDefaults keyed by
    /// `AppSessionID.current` so a fresh launch (new UUID) re-shows it.
    @State private var reauthBannerDismissed = false
    /// Independent dismiss key — silencing one provider's banner must not
    /// silence the other's.
    @State private var slackReauthBannerDismissed = false

    private var shouldShowReauthBanner: Bool {
        guard !reauthBannerDismissed else { return false }
        return !ReauthBannerKeys.isDismissed(ReauthBannerKeys.github)
    }

    private var shouldShowSlackReauthBanner: Bool {
        guard !slackReauthBannerDismissed else { return false }
        return !ReauthBannerKeys.isDismissed(ReauthBannerKeys.slack)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LeafSpace.xl) {
                if case .connectedScopeOutdated(let missing) = scopesReader.state, shouldShowReauthBanner {
                    reauthBanner(missingCount: missing.count)
                }

                if case .connectedScopeOutdated(let missing) = slackScopes.state, shouldShowSlackReauthBanner {
                    slackReauthBanner(missingCount: missing.count)
                }

                switch reader.state {
                case .loading:
                    LoadingScaffold()
                case .notConfigured(let msg):
                    notConfiguredFullPage(msg)
                case .empty(let msg):
                    emptyFullPage(msg)
                case .error(let msg, let lastKnown):
                    // Track-9 T6 (C-2 close) — banner above last-known content
                    // when available; cold-error keeps banner-only UX preserved.
                    if let snapshot = lastKnown {
                        VStack(alignment: .leading, spacing: LeafSpace.lg) {
                            errorBanner(msg)
                            HomeContent(snapshot: snapshot)
                        }
                    } else {
                        errorBanner(msg)
                    }
                case .loaded(let snapshot, _):
                    HomeContent(snapshot: snapshot)
                }
            }
            .padding(LeafSpace.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { reader.refresh() }
    }

    // MARK: - Re-auth banners (Track-3 D2/D3)

    @ViewBuilder
    private func reauthBanner(missingCount: Int) -> some View {
        LeafBanner(
            tone: .warning,
            title: "GitHub permissions need a refresh",
            description:
                "\(missingCount) new event type\(missingCount == 1 ? "" : "s") \(missingCount == 1 ? "is" : "are") blocked until you re-authorize.",
            ctaTitle: "Re-authorize",
            onCTA: {
                Task { await githubOAuth.connect(scopes: GitHubScopesService.requested()) }
            },
            onDismiss: {
                ReauthBannerKeys.markDismissed(ReauthBannerKeys.github)
                reauthBannerDismissed = true
            }
        )
    }

    @ViewBuilder
    private func slackReauthBanner(missingCount: Int) -> some View {
        LeafBanner(
            tone: .warning,
            title: "Slack permissions need a refresh",
            description:
                "\(missingCount) new event type\(missingCount == 1 ? "" : "s") \(missingCount == 1 ? "is" : "are") blocked until you re-authorize.",
            ctaTitle: "Re-authorize Slack",
            onCTA: {
                Task { await slackOAuth.connect() }
            },
            onDismiss: {
                ReauthBannerKeys.markDismissed(ReauthBannerKeys.slack)
                slackReauthBannerDismissed = true
            }
        )
    }

    // MARK: - State-machine renders

    @ViewBuilder
    private func notConfiguredFullPage(_ msg: String) -> some View {
        VStack {
            Spacer()
            LeafEmptyState(
                icon: LeafIcons.object.folderEmpty,
                title: "Connect a provider to enrich Home",
                description: msg,
                ctaTitle: "Open Connections",
                onCTA: { windowState.section = .connections }
            )
            Spacer()
        }
        .frame(minHeight: LeafEmptyStateTokens.centeredMinHeight)
    }

    @ViewBuilder
    private func emptyFullPage(_ msg: String) -> some View {
        VStack {
            Spacer()
            LeafEmptyState(
                icon: LeafIcons.brand.leaf,
                title: "Leaf is listening",
                description: msg
            )
            Spacer()
        }
        .frame(minHeight: LeafEmptyStateTokens.centeredMinHeight)
    }

    @ViewBuilder
    private func errorBanner(_ msg: String) -> some View {
        LeafBanner(
            tone: .danger,
            title: "Couldn't load Home",
            description: msg,
            ctaTitle: "Try again",
            onCTA: { reader.refresh() }
        )
    }
}

// MARK: - Loading scaffold

private struct LoadingScaffold: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xl) {
            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                Text("Reading recent activity…")
                    .font(LeafType.title.large)
                    .foregroundStyle(LeafColor.text.secondary)
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)  // P9 a11y: redundant with "Reading recent activity…" above
            }

            // Muted shape placeholders — no shimmer (D1 §22).
            ForEach(0..<3, id: \.self) { _ in
                LeafCard(padding: .regular) {
                    HStack {
                        Text("—")
                            .font(LeafType.body.regular)
                            .foregroundStyle(LeafColor.text.tertiary)
                        Spacer()
                    }
                }
                .accessibilityHidden(true)  // P9 a11y: decorative scaffold, em-dash would read literally
            }
        }
    }
}

// HomeContent extracted to Leaf/Views/Window/Home/HomeContent.swift (Track-10 T7 C4).
