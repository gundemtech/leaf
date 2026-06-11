//
//  AccountSettingsSection.swift
//  Track 5 / S8 / T9 — Settings page top section. Surfaces user identity
//  (display name from active workspace's self-member if available) + current
//  Tier chip + Free→Upgrade button.
//
//  Display name resolution: walks `WorkspaceReader.state` → active workspace
//  members → first row where `pubkeyHex == self`. Falls back to "Anonymous"
//  when no workspace has been joined yet (fresh-install path).
//
//  Tier chip variants:
//    .team  → green capsule with checkmark.seal.fill + "Team — early access"
//    .free  → "Upgrade" LeafButton triggering UpgradeModal (reuses the
//             T3/T4 modal + .submitToWaitlist env closure).
//
//  Note: pre-M027 this section also rendered «YOUR JOIN CODE» (a base32
//  encoding of the user's X25519 pubkey) for the S3 invite flow where the
//  inviter had to know the invitee's pubkey upfront. Under M027 admins issue
//  workspace-scoped tokens and invitees submit their pubkey via a join
//  request — the per-person join-code surface is no longer needed.
//

import AppKit
import CryptoKit
import LeafCore
import SwiftUI

struct AccountSettingsSection: View {
  @Environment(TierGateReader.self) private var tierGate
  @Environment(WorkspaceReader.self) private var workspaceReader
  @Environment(SupabaseOAuthService.self) private var loginService
  @Environment(\.submitToWaitlist) private var submitToWaitlist

  @State private var selfPubHex: String = ""
  @State private var showUpgrade = false
  @State private var showSignOutConfirm = false

  var body: some View {
    LeafSection(
      title: "Account",
      description: "Your local identity in this workspace."
    ) {
      VStack(alignment: .leading, spacing: LeafSpace.sm) {
        LeafCard(variant: .raised, padding: .regular) {
          HStack(alignment: .center, spacing: LeafSpace.md) {
            avatar
            Text(displayName)
              .font(LeafType.title.small)
              .foregroundStyle(LeafColor.text.primary)
            Spacer(minLength: 0)
            tierChip
          }
        }
        HStack(spacing: 0) {
          Spacer(minLength: 0)
          LeafButton("Sign Out", variant: .secondary, size: .sm) {
            showSignOutConfirm = true
          }
        }
      }
    }
    .confirmationDialog(
      "Sign out of Leaf?",
      isPresented: $showSignOutConfirm,
      titleVisibility: .visible
    ) {
      Button("Sign Out", role: .destructive) {
        Task { await loginService.signOut() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Background capture stops and you'll need to sign in again to use Leaf.")
    }
    .sheet(isPresented: $showUpgrade) {
      UpgradeModal(
        reason: .createWorkspace,
        onDismiss: { showUpgrade = false },
        onSubmitEmail: { email in await submitToWaitlist(email) }
      )
    }
    .task {
      loadSelfIdentity()
    }
  }

  // MARK: - Subviews

  private var avatar: some View {
    Image(systemName: "person.crop.circle.fill")
      .font(.system(size: 32))
      .foregroundStyle(LeafColor.accent.primary)
      .frame(width: 36, height: 36)
  }

  @ViewBuilder
  private var tierChip: some View {
    switch tierGate.tier {
    case .team:
      HStack(spacing: LeafSpace.xs) {
        Image(systemName: "checkmark.seal.fill")
          .font(.system(size: 12))
        Text("Team — early access")
          .font(LeafType.body.small)
      }
      .padding(.horizontal, LeafSpace.sm)
      .padding(.vertical, LeafSpace.xs)
      .background(
        Capsule().fill(LeafColor.status.success.opacity(0.15))
      )
      .foregroundStyle(LeafColor.status.success)
    case .free:
      LeafButton(
        "Upgrade",
        variant: .primary,
        size: .sm
      ) {
        showUpgrade = true
      }
    }
  }

  // MARK: - Helpers

  /// Display name resolution — pulls from the active workspace's self-member
  /// when a workspace is loaded. Fresh-install (no workspace) → "Anonymous".
  private var displayName: String {
    if case .loaded(_, _, let members) = workspaceReader.state,
      !selfPubHex.isEmpty,
      let me = members.first(where: { $0.pubkeyHex == selfPubHex }),
      !me.displayName.isEmpty
    {
      return me.displayName
    }
    return "Anonymous"
  }

  /// Resolve self pubkey from `IdentityService.ensureLocalIdentity` via the
  /// shared TeamKeystore root. Filesystem I/O — done once in `.task`.
  /// `selfPubHex` is kept for `displayName` resolution (matching against
  /// `TeamMember.pubkeyHex` in the active workspace member list).
  private func loadSelfIdentity() {
    do {
      let priv = try IdentityService.ensureLocalIdentity(at: TeamKeystore.defaultRoot())
      selfPubHex = priv.publicKey.rawRepresentation
        .map { String(format: "%02x", $0) }.joined()
    } catch {
      // Composition root logs identity errors elsewhere; UI falls back to
      // "Anonymous" via the displayName resolver.
      selfPubHex = ""
    }
  }
}
