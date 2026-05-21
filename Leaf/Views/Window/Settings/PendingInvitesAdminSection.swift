//
//  PendingInvitesAdminSection.swift
//  Track 5 / S7 — Relocated from Team/ to Settings/ (F.6). Admin-facing
//  pending-invites list within WorkspaceSettingsSection. Struct name unchanged
//  so TeamView callers compile without modification.
//  Section header has Refresh CTA via LeafButton.secondary (batch poll via
//  PendingInvitesReader.poll()). Per-row actions delegated to PendingInviteAdminRow.
//

import LeafCore
import SwiftUI

struct PendingInvitesSection: View {
  @Environment(PendingInvitesReader.self) private var reader

  var body: some View {
    switch reader.state {
    case .loading:
      // Pre-fix: rendered EmptyView() — a hung refresh and an empty
      // queue were visually indistinguishable, so debugging needed
      // console logs. Surface a tiny loading affordance under the
      // section header so the user can tell something's in flight.
      loadingContent
    case .error(let message):
      errorContent(message)
    case .loaded(let rows) where rows.isEmpty:
      EmptyView()
    case .loaded(let rows):
      content(rows)
    }
  }

  private var loadingContent: some View {
    LeafSection(title: "Pending invites") {
      HStack(spacing: LeafSpace.sm) {
        ProgressView()
        Text("Refreshing pending invites…")
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.text.secondary)
        Spacer()
      }
      .padding(.vertical, LeafSpace.sm)
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
