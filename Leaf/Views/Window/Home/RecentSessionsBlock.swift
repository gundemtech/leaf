//
//  RecentSessionsBlock.swift
//  Track 2 / D2 — Home Section 4 "RECENT SESSIONS · TODAY". Replaces the
//  previous Top Apps row with per-session list (window context + duration).
//  Top 8 sessions sorted by start desc.
//
//  Empty state: LeafEmptyState (D1 O7) с SF "clock.arrow.circlepath" instead
//  of bare text — gives the panel actual mass on a fresh install.
//

import SwiftUI
import LeafCore

struct RecentSessionsBlock: View {
    let sessions: [ActivitySession]

    private static let limit = 8

    private var topSessions: [ActivitySession] {
        Array(sessions.sorted { $0.start > $1.start }.prefix(Self.limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("RECENT SESSIONS · TODAY")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            LeafCard(padding: .regular) {
                if topSessions.isEmpty {
                    LeafEmptyState(
                        icon: LeafIcons.object.folderEmpty,
                        title: "No sessions yet",
                        description: "Switch between apps for a few minutes to start your timeline"
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(topSessions.enumerated()), id: \.element.id) { idx, session in
                            row(for: session)
                            if idx < topSessions.count - 1 {
                                LeafDivider(style: .soft)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for session: ActivitySession) -> some View {
        LeafListRow(
            primary: AppNameResolver.shared.displayName(for: session.bundleID),
            secondary: session.contextLabel,
            leading: { iconView(for: session) },
            trailing: {
                Text(formatDuration(session.duration))
                    .font(LeafType.mono.small)
                    .foregroundStyle(LeafColor.text.tertiary)
            }
        )
    }

    @ViewBuilder
    private func iconView(for session: ActivitySession) -> some View {
        if let nsImage = AppIconResolver.shared.icon(for: session.bundleID, size: LeafIconSize.md.pt) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: LeafIconSize.md.pt, height: LeafIconSize.md.pt)
        } else {
            LeafIcon(asset: LeafIcons.object.appPlaceholder, size: .md, tint: LeafColor.text.tertiary)
        }
    }
}
