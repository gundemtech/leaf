//
//  PendingInviteRow.swift
//  Track 2 / D3 — per-row layout for PendingInvitesSection on D1 substrate.
//  Status-driven action cluster:
//    .pending  → [Re-share popover] + [Revoke] (LeafIconButton.bordered/destructive)
//    .revoked / .expired / .failed → [Dismiss] (LeafButton.secondary)
//    .consumed → never rendered (filtered at DB-level by readAllPendingInvites).
//

import LeafCore
import SwiftUI

struct PendingInviteRow: View {
    let invite: PendingInvite
    let onRevoke: () -> Void
    let onDismiss: () -> Void

    @State private var showingResharePopover = false

    var body: some View {
        HStack(alignment: .center, spacing: LeafSpace.md) {
            LeafAvatar(initials: avatarInitials, size: .md)

            VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                HStack(spacing: LeafSpace.sm) {
                    Text(displayLabel)
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.primary)
                    statusBadge
                }
                Text(pubkeyShortHex(invite.inviteePubkeyHex))
                    .font(LeafType.mono.small)
                    .foregroundStyle(LeafColor.text.tertiary)
            }

            Spacer()

            actionCluster
        }
    }

    // MARK: - Subviews

    private var avatarInitials: String {
        let parts =
            displayLabel
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
        return parts.isEmpty ? "?" : parts
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch invite.status {
        case .pending:
            LeafBadge(text: "Awaiting", variant: .accent)
        case .revoked:
            LeafBadge(text: "Revoked", variant: .neutral)
        case .expired:
            LeafBadge(text: "Expired", variant: .neutral)
        case .failed:
            LeafBadge(text: "Failed", variant: .neutral)
        case .consumed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actionCluster: some View {
        switch invite.status {
        case .pending:
            HStack(spacing: LeafSpace.sm) {
                LeafIconButton(
                    asset: LeafIcons.comm.share,
                    variant: .secondary,
                    size: .md,
                    action: { showingResharePopover = true }
                )
                .popover(isPresented: $showingResharePopover) {
                    resharePopoverContent
                }

                LeafIconButton(
                    asset: LeafIcons.action.clear,
                    variant: .destructive,
                    size: .md,
                    action: onRevoke
                )
            }
        case .revoked, .expired, .failed:
            LeafButton("Dismiss", variant: .secondary, size: .sm, action: onDismiss)
        case .consumed:
            EmptyView()
        }
    }

    private var resharePopoverContent: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("Re-share invite link")
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
            Text("Sends the same link Leaf already issued — invitee can still open it.")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
                .frame(maxWidth: 280, alignment: .leading)
                .lineSpacing(2)

            ShareTemplateButton(
                templateBody: ShareTemplate.compose(
                    .adminShare(
                        displayName: invite.inviteeDisplayNameHint ?? "",
                        inviteURL: InviteURL.compose(token: invite.token, otp: invite.otp)
                    )),
                mailSubject: "Your Leaf invite link"
            )
        }
        .padding(LeafSpace.lg)
    }

    // MARK: - Helpers

    private var displayLabel: String {
        let trimmed = (invite.inviteeDisplayNameHint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Awaiting colleague" : trimmed
    }

    private func pubkeyShortHex(_ hex: String) -> String {
        guard hex.count >= 16 else { return hex }
        return "\(hex.prefix(8))…\(hex.suffix(8))"
    }
}
