//
//  ProfileAccountCard.swift
//  Leaf
//
//  Profile account identity card (Variant B) — parity with the web dashboard:
//  avatar(initials) + account name + Plan chip in the header; Email / Provider /
//  Member-since rows; "Change password on the web" link; Sign Out. Replaces
//  AccountSettingsSection (which was only used by ProfileView).
//

import AppKit
import CryptoKit
import LeafCore
import SwiftUI

struct ProfileAccountCard: View {
  @Environment(AccountProfileReader.self) private var profileReader
  @Environment(TierGateReader.self) private var tierGate
  @Environment(WorkspaceReader.self) private var workspaceReader
  @Environment(SupabaseOAuthService.self) private var loginService
  @Environment(\.submitToWaitlist) private var submitToWaitlist

  @State private var selfPubHex: String = ""
  @State private var showUpgrade = false
  @State private var showSignOutConfirm = false

  /// Web dashboard (password lives there per spec). Same host as LoginView links.
  private static let dashboardURL = URL(string: "https://leaf.gundem.tech/dashboard")!

  var body: some View {
    LeafSection(title: "Account", description: "Your Leaf account.") {
      LeafCard(variant: .raised, padding: .regular) {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
          header
          Divider()
          detailRow("Email", emailValue)
          detailRow("Provider", providerValue)
          detailRow("Member since", memberSinceValue)
          Link(destination: Self.dashboardURL) {
            Text("Change password on the web ↗")
              .font(LeafType.body.small)
              .foregroundStyle(LeafColor.accent.primary)
          }
          .buttonStyle(.plain)
          HStack {
            Spacer(minLength: 0)
            LeafButton("Sign Out", variant: .secondary, size: .sm) { showSignOutConfirm = true }
          }
        }
      }
    }
    .confirmationDialog(
      "Sign out of Leaf?", isPresented: $showSignOutConfirm, titleVisibility: .visible
    ) {
      Button("Sign Out", role: .destructive) { Task { await loginService.signOut() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Background capture stops and you'll need to sign in again to use Leaf.")
    }
    .sheet(isPresented: $showUpgrade) {
      UpgradeModal(
        reason: .createWorkspace,
        onDismiss: { showUpgrade = false },
        onSubmitEmail: { email in await submitToWaitlist(email) })
    }
    .task { loadSelfIdentity() }
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .center, spacing: LeafSpace.md) {
      avatar
      Text(displayName)
        .font(LeafType.title.small)
        .foregroundStyle(LeafColor.text.primary)
      Spacer(minLength: 0)
      tierChip
    }
  }

  private var avatar: some View {
    ZStack {
      Circle().fill(LeafColor.accent.primary.opacity(0.15))
      Text(initials)
        .font(LeafType.body.regular)
        .foregroundStyle(LeafColor.accent.primary)
    }
    .frame(width: 36, height: 36)
  }

  @ViewBuilder
  private var tierChip: some View {
    switch tierGate.tier {
    case .team:
      HStack(spacing: LeafSpace.xs) {
        Image(systemName: "checkmark.seal.fill").font(.system(size: 12))
        Text("Team — early access").font(LeafType.body.small)
      }
      .padding(.horizontal, LeafSpace.sm)
      .padding(.vertical, LeafSpace.xs)
      .background(Capsule().fill(LeafColor.status.success.opacity(0.15)))
      .foregroundStyle(LeafColor.status.success)
    case .free:
      LeafButton("Upgrade", variant: .primary, size: .sm) { showUpgrade = true }
    }
  }

  // MARK: - Rows

  private func detailRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: LeafSpace.sm) {
      Text(label)
        .font(LeafType.body.regular)
        .foregroundStyle(LeafColor.text.secondary)
        .frame(width: 110, alignment: .leading)
      Text(value)
        .font(LeafType.body.regular)
        .foregroundStyle(LeafColor.text.primary)
        .textSelection(.enabled)
      Spacer(minLength: 0)
    }
  }

  // MARK: - Values

  private var loadedProfile: SupabaseUserProfile? {
    if case .loaded(let p) = profileReader.state { return p }
    return nil
  }
  private var emailValue: String { loadedProfile?.email ?? "—" }
  private var providerValue: String { AccountProfileFormat.providerLabel(loadedProfile?.provider) }
  private var memberSinceValue: String {
    AccountProfileFormat.memberSince(isoString: loadedProfile?.createdAt) ?? "—"
  }

  /// Name: account full_name / email-local-part → workspace self-member name →
  /// "Local user".
  private var displayName: String {
    if let p = loadedProfile, let n = AccountProfileFormat.accountName(p) { return n }
    if case .loaded(_, _, let members) = workspaceReader.state,
      !selfPubHex.isEmpty,
      let me = members.first(where: { $0.pubkeyHex == selfPubHex }),
      !me.displayName.isEmpty
    {
      return me.displayName
    }
    return "Local user"
  }

  private var initials: String {
    displayName.first.map { String($0).uppercased() } ?? "?"
  }

  private func loadSelfIdentity() {
    do {
      let priv = try IdentityService.ensureLocalIdentity(at: TeamKeystore.defaultRoot())
      selfPubHex = priv.publicKey.rawRepresentation
        .map { String(format: "%02x", $0) }.joined()
    } catch {
      selfPubHex = ""
    }
  }
}
