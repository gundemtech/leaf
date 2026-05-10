//
//  PendingInviteRow.swift
//  Leaf
//
//  Phase 5.5.C — per-row layout for PendingInvitesSection. Status-driven action cluster:
//  .pending → [Re-share popover] + [Revoke]; .revoked / .expired / .failed → [Dismiss].
//  .consumed never rendered (filtered at DB-level by readAllPendingInvites per spec D1).
//

import SwiftUI
import LeafCore

struct PendingInviteRow: View {
    let invite: PendingInvite
    let onRevoke: () -> Void
    let onDismiss: () -> Void

    @State private var showingResharePopover = false

    var body: some View {
        HStack(spacing: 14) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(displayLabel)
                        .font(.leafBody)
                        .foregroundStyle(.leafInk)
                    statusBadge
                }
                Text(pubkeyShortHex(invite.inviteePubkeyHex))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.leafInk.opacity(0.55))
            }

            Spacer()

            actionCluster
        }
    }

    // MARK: - Subviews

    private var avatar: some View {
        let initials = displayLabel
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
        return Circle()
            .fill(Color.leafAccent.opacity(0.12))
            .frame(width: 36, height: 36)
            .overlay(
                Text(initials.isEmpty ? "?" : initials)
                    .font(.leafBody.monospacedDigit())
                    .foregroundStyle(.leafInk.opacity(0.6))
            )
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch invite.status {
        case .pending:
            badge(text: "Awaiting", colour: .leafAccentDeep, fill: Color.leafAccent.opacity(0.18))
        case .revoked:
            badge(text: "Revoked", colour: .leafInk.opacity(0.55), fill: Color.leafInk.opacity(0.08))
        case .expired:
            badge(text: "Expired", colour: .leafInk.opacity(0.55), fill: Color.leafInk.opacity(0.08))
        case .failed:
            badge(text: "Failed", colour: .red.opacity(0.85), fill: Color.red.opacity(0.10))
        case .consumed:
            // Filtered at DB level — defensive EmptyView для switch exhaustiveness.
            EmptyView()
        }
    }

    private func badge(text: String, colour: Color, fill: Color) -> some View {
        Text(text.uppercased())
            .font(.system(.caption2, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(fill, in: Capsule())
            .foregroundStyle(colour)
    }

    @ViewBuilder
    private var actionCluster: some View {
        switch invite.status {
        case .pending:
            HStack(spacing: 8) {
                Button {
                    showingResharePopover = true
                } label: {
                    Label("Re-share", image: LeafIcons.comm.share)
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $showingResharePopover) {
                    resharePopoverContent
                }

                Button(role: .destructive) {
                    onRevoke()
                } label: {
                    Label("Revoke", image: LeafIcons.action.clear)
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
            }
        case .revoked, .expired, .failed:
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.bordered)
        case .consumed:
            EmptyView()
        }
    }

    private var resharePopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Re-share invite link")
                .font(.leafLabel)
                .foregroundStyle(.leafInk)
            Text("Sends the same link Leaf already issued — invitee can still open it.")
                .font(.leafCaption)
                .foregroundStyle(.leafInk.opacity(0.7))
                .frame(maxWidth: 280, alignment: .leading)
                .lineSpacing(2)

            ShareTemplateButton(
                templateBody: ShareTemplate.compose(.adminShare(
                    displayName: invite.inviteeDisplayNameHint ?? "",
                    inviteURL: InviteURL.compose(token: invite.token, otp: invite.otp)
                )),
                mailSubject: "Your Leaf invite link"
            )
        }
        .padding(16)
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
