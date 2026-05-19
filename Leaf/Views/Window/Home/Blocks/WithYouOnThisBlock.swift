//
//  WithYouOnThisBlock.swift
//  Track-8 / Phase 8.5 — Home WITH YOU ON THIS dashboard cell. Renders
//  up to 5 teammate rows surfaced by
//  `DerivedInsights.sameTaskTeammates(rule: .hierarchical)`. Substrate
//  (Phase 8.1 `SameTaskMatcher`) resolves rule + sort: confidence asc →
//  lastActivityAtMs desc → displayName asc. Returns [] until Phase 5.4
//  wires DBTeammatePresenceReader against `presence_history`, so this
//  block typically renders the empty state in production today.
//
//  Master spec §4.3: 5-row cap, "+N more" overflow, empty state with
//  Team CTA. Offline footer + "N active elsewhere" count are P5 carry
//  to §9.1 (C-10, C-11) — pending Phase 5.4 / 5.6 substrate.
//

import LeafCore
import SwiftUI

struct WithYouOnThisBlock: View {
    let matches: [TeammateMatch]

    @Environment(WindowState.self) private var windowState

    private static let rowCap = 5

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("WITH YOU ON THIS")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            LeafCard(padding: .regular) {
                if matches.isEmpty {
                    emptyState
                } else {
                    populatedBody
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: matches)
    }

    @ViewBuilder
    private var emptyState: some View {
        LeafEmptyState(
            icon: LeafIcons.brand.leaf,
            title: "No one's on this task right now.",
            description:
                "Teammates working on the same Linear issue, branch, or adjacent branch will appear here.",
            ctaTitle: "→ Team",
            onCTA: { windowState.section = .team }
        )
    }

    @ViewBuilder
    private var populatedBody: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            ForEach(matches.prefix(Self.rowCap), id: \.memberID) { match in
                teammateRow(match)
            }
            if matches.count > Self.rowCap {
                overflowFooter(remaining: matches.count - Self.rowCap)
            }
        }
    }

    @ViewBuilder
    private func overflowFooter(remaining: Int) -> some View {
        Button {
            windowState.section = .team
        } label: {
            Text("→ +\(remaining) more on this task")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.accent.primary)
        }
        .buttonStyle(.plain)
        .padding(.top, LeafSpace.xs)
        .accessibilityLabel("Show \(remaining) more teammates in Team tab")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func teammateRow(_ match: TeammateMatch) -> some View {
        Button {
            windowState.section = .team
        } label: {
            HStack(alignment: .center, spacing: LeafSpace.md) {
                avatarCircle(for: match)
                VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                    Text(match.displayName)
                        .font(LeafType.title.small)
                        .foregroundStyle(LeafColor.text.primary)
                        .lineLimit(1)
                    Text(secondLine(for: match))
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                confidenceBadge(for: match)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(match.displayName), \(match.contextLabel), tap to open Team tab")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func avatarCircle(for match: TeammateMatch) -> some View {
        Circle()
            .fill(avatarTint(forMemberID: match.memberID))
            .frame(width: 32, height: 32)
            .overlay(
                Text(initials(match.displayName))
                    .font(LeafType.body.small)
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func confidenceBadge(for match: TeammateMatch) -> some View {
        let tint = confidenceTint(match.confidence)
        Text(match.contextLabel)
            .font(LeafType.body.small)
            .foregroundStyle(tint)
            .padding(.horizontal, LeafSpace.sm)
            .padding(.vertical, LeafSpace.xxs)
            .background(
                RoundedRectangle(cornerRadius: LeafRadius.sm, style: .continuous)
                    .fill(tint.opacity(0.15))
            )
            .accessibilityHidden(true)
    }

    private func secondLine(for match: TeammateMatch) -> String {
        let app = match.currentApp ?? "—"
        return "\(app) · \(formatRelative(msAgo: match.lastActivityAtMs))"
    }

    private func confidenceTint(_ confidence: MatchConfidence) -> Color {
        switch confidence {
        case .onSameLinearIssue, .onSameBranch:
            return LeafColor.status.success
        case .onAdjacentBranch:
            return LeafColor.status.warning
        }
    }

    /// Deterministic palette pick by member id — visual aid only, not
    /// identity. Swift's String.hashValue is randomized across launches,
    /// so the tint may drift between runs. Acceptable in P5; P9 carry
    /// could swap to a stable hash if it bothers.
    ///
    /// Palette deliberately excludes `status.warning` and `status.success`
    /// because those are the badge tints in `confidenceTint(_:)`; reusing
    /// them on the avatar would create a false semantic pairing
    /// (an amber circle next to an amber "adjacent branch" badge reads
    /// as if the avatar itself encodes confidence).
    private func avatarTint(forMemberID id: String) -> Color {
        let palette: [Color] = [
            LeafColor.accent.primary,
            LeafColor.accent.emphasis,
            LeafColor.status.info,
            LeafColor.status.danger,
            LeafColor.text.secondary,
        ]
        let hash = abs(id.hashValue)
        return palette[hash % palette.count]
    }

    /// "Dmitrii Demidov" → "DD", "Anton" → "A", "" → "?".
    private func initials(_ displayName: String) -> String {
        let parts = displayName.split(separator: " ").prefix(2)
        let chars = parts.compactMap { $0.first.map(String.init) }
        let joined = chars.joined().uppercased()
        return joined.isEmpty ? "?" : String(joined.prefix(2))
    }

    /// C-22 (Phase 8.9) — migrated to `HomeRelativeTimeFormatter`. Kept as a
    /// thin wrapper so existing call sites in the body stay one-liner; bucket
    /// ladder semantics change from "Ns / Nm / Nh / Nd ago" to the canonical
    /// "now / Nm ago / Nh ago / yesterday / N days ago / MMM d" shared with
    /// WhereStoppedBlock + YouNowBlock.
    private func formatRelative(msAgo ms: Int64) -> String {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return HomeRelativeTimeFormatter.format(deltaMs: max(0, nowMs - ms), nowMs: nowMs)
    }
}
