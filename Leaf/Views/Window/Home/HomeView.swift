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
//    .loading        → ProgressView centered in hero region (no shimmer).
//    .notConfigured  → Full-page LeafEmptyState + 'Open Connections' CTA.
//    .empty          → Full-page LeafEmptyState (no CTA).
//    .error          → LeafBanner.danger at top + 'Try again' CTA + last-known content.
//    .loaded         → HomeContent (extracted) — 4-zone render.
//
//  NavigationStack destinations live on HomeContent.
//

import SwiftUI
import LeafCore

private let knownLinearPrefixesForHero: Set<String> = ["LEAF"]

/// Hero app-icon size — 36pt. With `heroIconAnchor` (top = title cap-top) the
/// icon's top edge sits on the title's cap-top line, its bottom edge on the
/// middle of the caption. Not part of LeafIconSize tokens (.xl = 32pt) — hero
/// is the only 36pt consumer.
private let heroIconSize: CGFloat = 36

/// Bleached leaf-green for cosmetic accent tints (provider row icons,
/// RIGHT NOW column headers). `accent.subtle` in dark mode = 35%-alpha
/// dark-green fill — unreadable as a foreground tint. We use
/// primary with opacity — same hue, reads softer.
extension Color {
    static var leafAccentBleached: Color { LeafColor.accent.primary.opacity(0.6) }
}

/// Custom alignment guide — pins icon top to title cap-top, not center-to-center.
/// The title frame includes leading above the cap-line (for 28pt SF Pro Display
/// semibold ≈ 7pt above the «T»), so icon center = title frame center visually
/// places the squircle above the cap-line. We compute cap-top as
/// `firstTextBaseline - capHeight`; capHeight ≈ 0.71 of font size for SF Pro
/// Display semibold (Apple metrics; 0.71 — empirical, not from Apple docs).
extension VerticalAlignment {
    private struct HeroIconAnchor: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.top]
        }
    }
    static let heroIconAnchor = VerticalAlignment(HeroIconAnchor.self)
}

/// Cap-height ratio for SF Pro Display semibold — empirical.
private let heroTitleCapHeightRatio: CGFloat = 0.71

/// Hero caption fallback truncation when no Linear ID matches the active
/// session's contextLabel — caps at this many chars before middle-truncating
/// (window titles get long fast: "leaf — D1 Design finish — caffeinate ◂…").
/// Tuned so the caption reads cleanly on the default window's hero region
/// without bleeding into next line.
private let heroContextMaxLength: Int = 40

struct HomeView: View {
    @Environment(InsightsReader.self) private var reader
    @Environment(WindowState.self) private var windowState
    // MARK: requires GitHubScopesReader env injection (Task 21)
    @Environment(GitHubScopesReader.self) private var scopesReader
    @Environment(GitHubOAuthService.self) private var githubOAuth
    // MARK: requires SlackScopesReader env injection (Phase Track-3 D3 / Task 18)
    @Environment(SlackScopesReader.self) private var slackScopes
    @Environment(SlackOAuthService.self) private var slackOAuth

    /// Session-local dismiss flag for the proactive GitHub re-auth banner.
    /// Persisted across the same launch via UserDefaults keyed by
    /// `AppSessionID.current` so a fresh launch (new UUID) re-shows the banner.
    @State private var reauthBannerDismissed = false
    /// Same per-launch dismiss pattern, separate key — Slack banner is
    /// independent of GitHub banner; dismissing one must not silence the other.
    @State private var slackReauthBannerDismissed = false

    private static let reauthBannerDismissKey = "github.reauth.bannerDismissedSessionID"
    private static let slackReauthBannerDismissKey = "slack.reauth.bannerDismissedSessionID"

    private var shouldShowReauthBanner: Bool {
        guard !reauthBannerDismissed else { return false }
        let saved = UserDefaults.standard.string(forKey: Self.reauthBannerDismissKey)
        return saved != AppSessionID.current
    }

    private var shouldShowSlackReauthBanner: Bool {
        guard !slackReauthBannerDismissed else { return false }
        let saved = UserDefaults.standard.string(forKey: Self.slackReauthBannerDismissKey)
        return saved != AppSessionID.current
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LeafSpace.xl) {
                if case let .connectedScopeOutdated(missing) = scopesReader.state, shouldShowReauthBanner {
                    reauthBanner(missingCount: missing.count)
                }

                if case let .connectedScopeOutdated(missing) = slackScopes.state, shouldShowSlackReauthBanner {
                    slackReauthBanner(missingCount: missing.count)
                }

                switch reader.state {
                case .loading:
                    LoadingScaffold()
                case .notConfigured(let msg):
                    notConfiguredFullPage(msg)
                case .empty(let msg):
                    emptyFullPage(msg)
                case .error(let msg):
                    errorBanner(msg)
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

    // MARK: - Re-auth banner

    /// Phase Track-3 D2 / Task 18 — proactive GitHub scope-bump banner. Surfaces
    /// the moment Home renders if `GitHubScopesReader` reports outdated scopes
    /// (alpha users grew up before the D2 bump). One CTA «Re-authorize» runs
    /// the full Device Flow with the canonical requested scope set; the
    /// secondary X dismiss stamps `AppSessionID.current` into UserDefaults so
    /// the banner stays gone for the rest of this launch but re-appears on the
    /// next (fresh UUID).
    @ViewBuilder
    private func reauthBanner(missingCount: Int) -> some View {
        LeafBanner(
            tone: .warning,
            title: "GitHub permissions need a refresh",
            description: "\(missingCount) new event type\(missingCount == 1 ? "" : "s") \(missingCount == 1 ? "is" : "are") blocked until you re-authorize.",
            ctaTitle: "Re-authorize",
            onCTA: {
                Task { await githubOAuth.connect(scopes: GitHubScopesService.requested()) }
            },
            onDismiss: {
                UserDefaults.standard.set(AppSessionID.current,
                                          forKey: Self.reauthBannerDismissKey)
                reauthBannerDismissed = true
            }
        )
    }

    /// Phase Track-3 D3 / Task 19 — proactive Slack scope-bump banner. Mirrors
    /// the GitHub banner above byte-for-byte; uses an independent per-launch
    /// `AppSessionID.current` dismiss key so the two providers' banners are
    /// silenced separately. CTA calls `slackOAuth.connect()` — its default
    /// arg path uses `SlackScopesService.requested()` (see Task 10).
    @ViewBuilder
    private func slackReauthBanner(missingCount: Int) -> some View {
        LeafBanner(
            tone: .warning,
            title: "Slack permissions need a refresh",
            description: "\(missingCount) new event type\(missingCount == 1 ? "" : "s") \(missingCount == 1 ? "is" : "are") blocked until you re-authorize.",
            ctaTitle: "Re-authorize Slack",
            onCTA: {
                Task { await slackOAuth.connect() }
            },
            onDismiss: {
                UserDefaults.standard.set(AppSessionID.current,
                                          forKey: Self.slackReauthBannerDismissKey)
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
            onCTA: { reader.refresh(force: true) }
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
            }
        }
    }
}

// HomeContent extracted to Leaf/Views/Window/Home/HomeContent.swift (Track-10 T7 C4).
