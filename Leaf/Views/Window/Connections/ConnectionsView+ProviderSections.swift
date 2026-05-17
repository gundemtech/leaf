//
//  ConnectionsView+ProviderSections.swift
//  Provider-section layout helpers: 28pt logo tile + title row + content slot.
//  Two variants — asset-backed (Linear / GitHub / Slack) and SF Symbol-backed
//  (Google Calendar). Title cap-top alignment guide pinned to provider logo.
//

import SwiftUI
import LeafCore

extension ConnectionsView {

    // MARK: - Provider blocks

    var providerBlocks: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xl) {
            providerSection(
                logoAsset: "leaf-brand-linear",
                logoTileColor: .black,
                title: "Linear",
                description: "Read-only access — issue activity (assigned, updated, completed) into your local timeline."
            ) {
                LeafCard(variant: .raised, padding: .regular) {
                    linearContent
                }
            }

            providerSection(
                logoAsset: "leaf-brand-github",
                logoTileColor: .white,
                title: "GitHub",
                description: "Read-only access — self-authored events (commits, PRs, issues, reviews) into your local timeline."
            ) {
                VStack(alignment: .leading, spacing: LeafSpace.lg) {
                    LeafCard(variant: .raised, padding: .regular) {
                        githubContent
                    }
                    if shouldShowScopesSection {
                        scopesSection
                    }
                }
            }

            providerSection(
                logoAsset: "leaf-brand-slack",
                logoTileColor: .white,
                title: "Slack",
                description: "Read-only access — self-authored message counts per channel and huddle minutes into your local timeline."
            ) {
                VStack(alignment: .leading, spacing: LeafSpace.lg) {
                    LeafCard(variant: .raised, padding: .regular) {
                        slackContent
                    }
                    if shouldShowSlackScopesSection {
                        slackScopesSection
                    }
                }
            }

            // Track-6 P4 — Google Calendar row. SF Symbol fallback (no
            // Asset-Catalog brand glyph shipped yet) on a white tile to match
            // GitHub/Slack contrast; Google's brand mark requires distribution
            // sign-off so we surface a neutral system symbol for MVP.
            providerSectionSymbol(
                systemSymbol: "calendar.circle.fill",
                logoTileColor: .white,
                symbolTint: Color("BrandGoogleBlue"),
                title: "Google Calendar",
                description: "Read-only access — meeting metadata (titles, times, attendee counts) into your local timeline. Attendee identities and event bodies stay on Google."
            ) {
                LeafCard(variant: .raised, padding: .regular) {
                    googleCalendarContent
                }
            }
        }
    }

    /// Mirrors LeafSection (Organism O2) layout but prepends a 28pt brand
    /// logo on a rounded tile to the title row, top-aligned to the title's
    /// cap-top via `.providerLogoAnchor` (matches Home hero icon pattern).
    ///
    /// `logoTileColor` is per-provider because each brand logo file ships in
    /// a specific contrast variant: GitHub black Octocat + Slack 4-colour glyph
    /// → white tile; Linear ships as white-on-dark variant → black tile.
    /// Each on its canonical brand surface; nil = no tile (raw logo).
    func providerSection<Content: View>(
        logoAsset: String,
        logoTileColor: Color?,
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            HStack(alignment: .providerLogoAnchor, spacing: LeafSpace.sm) {
                providerLogo(asset: logoAsset, tileColor: logoTileColor)
                    .alignmentGuide(.providerLogoAnchor) { $0[.top] }
                VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                    Text(title)
                        .font(LeafSectionTokens.titleFont)
                        .foregroundStyle(LeafColor.text.primary)
                        .alignmentGuide(.providerLogoAnchor) { d in
                            d[.firstTextBaseline] - providerTitleFontSize * providerTitleCapHeightRatio
                        }
                    Text(description)
                        .font(LeafSectionTokens.descriptionFont)
                        .foregroundStyle(LeafColor.text.secondary)
                }
            }
            content()
        }
    }

    /// 28pt total dimension. With tile: RoundedRectangle (LeafRadius.sm) in
    /// `tileColor` + 20pt inner logo centered (~4pt padding each side).
    /// `tileColor: nil` → logo at full 28pt without tile.
    @ViewBuilder
    func providerLogo(asset: String, tileColor: Color?) -> some View {
        let outer: CGFloat = 28                   // raw — between LeafIconSize.lg (24) and .xl (32)
        let inner: CGFloat = 20                   // logo glyph inside tile
        if let tileColor {
            ZStack {
                RoundedRectangle(cornerRadius: LeafRadius.sm, style: .continuous)
                    .fill(tileColor)
                Image(asset)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: inner, height: inner)
            }
            .frame(width: outer, height: outer)
        } else {
            Image(asset)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: outer, height: outer)
        }
    }

    // MARK: - Provider section (SF Symbol variant — Track-6 P4)

    /// Mirror of `providerSection` but with an SF Symbol glyph instead of an
    /// Asset-Catalog image. Used for Google Calendar where we don't yet ship
    /// a brand-cleared image asset. `symbolTint` colors the glyph itself
    /// (foregroundStyle on the SF Symbol); the tile background uses
    /// `logoTileColor` like the asset variant.
    func providerSectionSymbol<Content: View>(
        systemSymbol: String,
        logoTileColor: Color?,
        symbolTint: Color,
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            HStack(alignment: .providerLogoAnchor, spacing: LeafSpace.sm) {
                providerSymbol(systemSymbol: systemSymbol, tileColor: logoTileColor, tint: symbolTint)
                    .alignmentGuide(.providerLogoAnchor) { $0[.top] }
                VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                    Text(title)
                        .font(LeafSectionTokens.titleFont)
                        .foregroundStyle(LeafColor.text.primary)
                        .alignmentGuide(.providerLogoAnchor) { d in
                            d[.firstTextBaseline] - providerTitleFontSize * providerTitleCapHeightRatio
                        }
                    Text(description)
                        .font(LeafSectionTokens.descriptionFont)
                        .foregroundStyle(LeafColor.text.secondary)
                }
            }
            content()
        }
    }

    /// Same 28pt-outer / 20pt-inner sizing as `providerLogo` so the new row
    /// aligns vertically with the asset-backed rows (Linear/GitHub/Slack).
    @ViewBuilder
    func providerSymbol(systemSymbol: String, tileColor: Color?, tint: Color) -> some View {
        let outer: CGFloat = 28
        let inner: CGFloat = 20
        if let tileColor {
            ZStack {
                RoundedRectangle(cornerRadius: LeafRadius.sm, style: .continuous)
                    .fill(tileColor)
                Image(systemName: systemSymbol)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(tint)
                    .frame(width: inner, height: inner)
            }
            .frame(width: outer, height: outer)
        } else {
            Image(systemName: systemSymbol)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(tint)
                .frame(width: outer, height: outer)
        }
    }
}
