//
//  TeamNBlock.swift
//  Track-10 T6 — Home Zone-3 TEAM·N broader pulse. Replaces the narrow
//  WithYouOnThisBlock (Phase 8.5) which only surfaced same-task teammates.
//  T6 renders everyone last-seen ≤ 15 min from
//  `TeammatePresenceReader.recentTeammateSnapshots(maxAge:now:)`. Reader
//  stub returns `[]` until Phase 5.4 wires `DBTeammatePresenceReader`
//  against `presence_history`, so this block renders the empty CTA
//  "Team presence sync coming soon." in production today (memberCount > 1
//  is gated upstream by `HomeView` against `OrgService.activeMemberCount()`).
//
//  Pure composition helpers (metaLine / initials / sort / paletteIndex /
//  a11yLabel / visibleCap) live in `LeafCore/Home/TeamNRowComposer.swift`
//  for unit-test coverage; the body is a thin shell over them. NON-tappable
//  rows per Track-9 §9.1 C-12 carry — Phase 5.4 owns the per-teammate
//  detail screen.
//

import LeafCore
import SwiftUI

struct TeamNBlock: View {
    let teammates: [TeammateSnapshot]

    @State private var isExpanded: Bool = false

    private var sorted: [TeammateSnapshot] {
        TeamNRowComposer.sorted(teammates)
    }

    private var visibleSlice: [TeammateSnapshot] {
        isExpanded ? sorted : Array(sorted.prefix(TeamNRowComposer.visibleCap))
    }

    private var overflowCount: Int {
        max(0, sorted.count - TeamNRowComposer.visibleCap)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("TEAM · \(teammates.count) · active")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)
                .accessibilityLabel(Self.headerA11yLabel(count: teammates.count))
                .accessibilityAddTraits(.isHeader)

            LeafCard(padding: .regular) {
                if teammates.isEmpty {
                    emptyState
                } else {
                    populatedBody
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: teammates)
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        LeafEmptyState(
            icon: LeafIcons.brand.leaf,
            title: "Team presence sync coming soon.",
            description: nil,
            ctaTitle: nil,
            onCTA: nil
        )
    }

    // MARK: - Populated body

    @ViewBuilder
    private var populatedBody: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            ForEach(visibleSlice, id: \.memberID) { snapshot in
                row(snapshot)
            }
            if overflowCount > 0 {
                expandFooter(remaining: overflowCount)
            }
        }
    }

    @ViewBuilder
    private func row(_ snapshot: TeammateSnapshot) -> some View {
        // Compute the relative-time string ONCE per render pass and reuse for
        // both the visible Text and the a11y label. Two independent Date()
        // reads can drift across the 60s bucket boundary under a slow render,
        // producing "now" for VO while the visible Text reads "1m ago".
        let relative = formatRelative(msAgo: snapshot.lastActivityAtMs)
        HStack(alignment: .center, spacing: LeafSpace.md) {
            avatarCircle(for: snapshot)
            VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                Text(snapshot.displayName)
                    .font(LeafType.title.small)
                    .foregroundStyle(LeafColor.text.primary)
                    .lineLimit(1)
                if let meta = TeamNRowComposer.metaLine(snapshot) {
                    Text(meta)
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            Text(relative)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(TeamNRowComposer.a11yLabel(snapshot, relativeTime: relative))
    }

    @ViewBuilder
    private func avatarCircle(for snapshot: TeammateSnapshot) -> some View {
        Circle()
            .fill(avatarTint(forMemberID: snapshot.memberID))
            // LeafSpace.xxl = 32pt avatar (semantic spacing-scale mapping).
            .frame(width: LeafSpace.xxl, height: LeafSpace.xxl)
            .overlay(
                Text(TeamNRowComposer.initials(snapshot.displayName))
                    .font(LeafType.body.small)
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func expandFooter(remaining: Int) -> some View {
        Button {
            isExpanded.toggle()
        } label: {
            Text(isExpanded ? "Show less" : "→ +\(remaining) more")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.accent.primary)
        }
        .buttonStyle(.plain)
        .padding(.top, LeafSpace.xs)
        .accessibilityLabel(
            isExpanded
                ? "Collapse list"
                : "Show \(remaining) more teammate\(remaining == 1 ? "" : "s")"
        )
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Tint palette + relative time

    /// 5-token palette matches WithYouOnThisBlock line 163-169 verbatim so the
    /// retired block's color discipline carries forward (no raw `Color.*`,
    /// passes `just check-tokens` 3-tier gate).
    private func avatarTint(forMemberID id: String) -> Color {
        let palette: [Color] = [
            LeafColor.accent.primary,
            LeafColor.accent.emphasis,
            LeafColor.status.info,
            LeafColor.status.danger,
            LeafColor.text.secondary,
        ]
        let idx = TeamNRowComposer.paletteIndex(memberID: id, paletteCount: palette.count)
        return palette[idx]
    }

    private func formatRelative(msAgo ms: Int64) -> String {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return HomeRelativeTimeFormatter.format(deltaMs: max(0, nowMs - ms), nowMs: nowMs)
    }

    /// VoiceOver header label with 0/1/N pluralization.
    /// Visual chip uses compact "TEAM · N · active"; VO reads natural English.
    static func headerA11yLabel(count: Int) -> String {
        switch count {
        case 0: return "Team, no members active"
        case 1: return "Team, 1 member active"
        default: return "Team, \(count) members active"
        }
    }
}
