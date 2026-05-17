//
//  PendingInvitesSection.swift
//  Track 2 / D3 — TeamView section between active members list и [Add member]
//  CTA on D1 substrate. Hidden when no visible rows (Phase 5.5.C contract D6).
//  Section header has Refresh CTA via LeafButton.secondary (batch poll via
//  PendingInvitesReader.poll()). Per-row actions delegated to PendingInviteRow.
//

import LeafCore
import SwiftUI

struct PendingInvitesSection: View {
    @Environment(PendingInvitesReader.self) private var reader

    var body: some View {
        switch reader.state {
        case .loading:
            EmptyView()
        case .error(let message):
            errorContent(message)
        case .loaded(let rows) where rows.isEmpty:
            EmptyView()
        case .loaded(let rows):
            content(rows)
        }
    }

    // MARK: - Loaded content

    private func content(_ rows: [PendingInvite]) -> some View {
        LeafSection(title: "Pending invites · \(rows.count)") {
            VStack(alignment: .leading, spacing: LeafSpace.md) {
                LeafCard(variant: .raised, padding: .tight) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.token) { idx, invite in
                            PendingInviteRow(
                                invite: invite,
                                onRevoke: { reader.revoke(token: invite.token) },
                                onDismiss: { reader.dismiss(token: invite.token) }
                            )
                            .padding(.horizontal, LeafSpace.md)
                            .padding(.vertical, LeafSpace.sm)

                            if idx < rows.count - 1 {
                                LeafDivider(style: .soft)
                                    .padding(.leading, LeafSpace.xxxl)
                            }
                        }
                    }
                }

                if let message = reader.pollMessage {
                    LeafBanner(
                        tone: .info,
                        title: "Poll outcome",
                        description: message,
                        onDismiss: { reader.acknowledgePollMessage() }
                    )
                }
            }
        } cta: {
            refreshButton
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        if reader.isPolling {
            HStack(spacing: LeafSpace.xs) {
                ProgressView().controlSize(.small)
                Text("Refreshing…")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
            }
        } else {
            LeafButton(
                "Refresh",
                variant: .secondary,
                size: .sm,
                icon: .asset(LeafIcons.action.refresh),
                action: { reader.poll() }
            )
        }
    }

    // MARK: - Error content

    private func errorContent(_ message: String) -> some View {
        LeafSection(title: "Pending invites") {
            LeafBanner(
                tone: .danger,
                title: "Couldn't load pending invites",
                description: message,
                ctaTitle: "Try again",
                onCTA: { reader.refresh() }
            )
        }
    }
}
