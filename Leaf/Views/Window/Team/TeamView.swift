//
//  TeamView.swift
//  Track 5 / S7 G.2-G.11 — Unified Team feed layout.
//  Team → Workspace Hub — page orchestrator. The feed surface (filter
//  chips + card dispatch + empty states + pagination + deep-link scroll)
//  was extracted verbatim into Tabs/TeamFeedTab.swift; TeamView keeps:
//
//    • tier gate (Free → TeamFeedFreePreview)
//    • workspaceReader state switch (.loading/.empty/.loaded/.error/.removed)
//    • toolbar + member strip (hub header + LeafTab replace these next)
//    • all sheets (SendDirectMessageSheet / GenerateInviteSheet /
//      WorkspaceCreateSheet / UpgradeModal)
//    • feed data-loading ownership: root `.task(id: activeWorkspaceID)` +
//      `.onChange(feedFilterStore.selected)` + the cached self-pubkey —
//      the feed loads/refreshes regardless of which hub tab is mounted
//      (TeamFeedReader holds state independent of view mount; unread
//      badges + APNs deep links depend on it).
//
//  Send entry:
//    • Tapping a member pill opens SendDirectMessageSheet for that member.
//    • [+ Send] toolbar button opens GenerateInviteSheet (⌘N).
//
//  S6 closure-injection pattern preserved 1:1 from OrganizationView:
//    • onReauthorizeSlack  — SlackOAuthService.connect()
//    • resolveLinearAssignee — LinearUsersResolver.resolve(displayName:)
//

import CryptoKit
import LeafCore
import SwiftUI

struct TeamView: View {

  // MARK: - Environment (S2/S4/S5/S6 — already in composition root)

  @Environment(WorkspaceReader.self) private var workspaceReader
  @Environment(ActiveWorkspaceStore.self) private var activeWorkspaceStore
  @Environment(TeamEventMirrorReader.self) private var teamEventMirrorReader
  // S6 closure providers (identical wiring pattern to OrganizationView).
  @Environment(SlackOAuthService.self) private var slackOAuth
  @Environment(\.linearUsersResolver) private var linearUsersResolver
  /// T4 — tier gate. Free-tier renders `TeamFeedFreePreview` mockup
  /// instead of the regular feed; `.canSendDM` is the canonical Free signal
  /// (matches gates used by SendDirectMessageSheet so the experience is
  /// internally consistent — Free users see the same lock everywhere).
  @Environment(TierGateReader.self) private var tierGate
  @Environment(\.submitToWaitlist) private var submitToWaitlist

  @Environment(TeamFeedReader.self) private var teamFeedReader
  @Environment(FeedFilterStore.self) private var feedFilterStore
  @Environment(CrossPostLogReader.self) private var crossPostLogReader
  @Environment(LiveUpdateSignals.self) private var liveSignals
  /// Deep-link plumbing: APNs handlers set `pendingMessageID` /
  /// `pendingHubTab`; the hub forces the matching tab before TeamFeedTab's
  /// own scroll-to observer (initial: true) picks the message up.
  @Environment(WindowState.self) private var windowState

  // MARK: - Local sheet state

  @State private var sendSheetRecipient: SendRecipient? = nil
  @State private var generateInvitePresented: Bool = false
  /// Surfaces the WorkspaceCreateSheet from Team's `.empty` workspace state
  /// CTA (M027 invite-redesign — no-workspace path).
  @State private var createWorkspacePresented: Bool = false

  /// Identifiable wrapper for sheet(item:). TeamMember is Hashable+Sendable but
  /// not Identifiable; wrap its id + member ref.
  private struct SendRecipient: Identifiable {
    let id: String  // matches TeamMember.id
    let member: TeamMember
    /// AI-UI-3 — pre-selected sheet kind (chat [+] menu picks Task/Handoff).
    var kind: DirectMessageKind = .ping
  }

  /// S7 Stage 6 fix C-I6 — cached self-pubkey hex. Loaded once via
  /// `loadCachedSelfPubHex()`; consulted by `selfPubkeyHex()`.
  /// Replaces a per-render call to `IdentityService.ensureLocalIdentity`
  /// (filesystem I/O on the main thread inside the LazyVStack body). Empty
  /// string == "not yet loaded" / "no identity" — TeamFeedReader treats
  /// that as no self-exclusion (graceful).
  @State private var cachedSelfPubHex: String = ""

  /// T4 — per-callsite UpgradeModal flag for the Free-tier preview branch.
  @State private var showUpgrade: Bool = false

  /// Hub tab selection. Deliberately NOT persisted: Feed is the page's
  /// identity (sidebar unread badges, APNs deep links and the "Team"
  /// mental model all land there); Members/Settings are occasional
  /// management detours. Persisting would resurrect a stale tab after
  /// relaunch and fight every deep link. Selection survives workspace
  /// switches within a session, resets to Feed per launch.
  @State private var hubTab: TeamHubTab = .chats

  // MARK: - Body

  /// S7 Stage 6 fix C-I6 — loads `cachedSelfPubHex` once per view appearance.
  /// `IdentityService.ensureLocalIdentity` reads the X25519 priv-key file
  /// from `<TeamKeystore.defaultRoot()>/x25519.priv`; doing this on every
  /// directMessageCard render is per-row filesystem I/O on the main thread.
  private func loadCachedSelfPubHex() {
    guard cachedSelfPubHex.isEmpty,
      let key = try? IdentityService.ensureLocalIdentity(at: TeamKeystore.defaultRoot())
    else { return }
    cachedSelfPubHex = key.publicKey.rawRepresentation
      .map { String(format: "%02x", $0) }
      .joined()
  }

  var body: some View {
    Group {
      // T4 — Free-tier branch: replace the entire feed body with the
      // mockup preview + Upgrade CTA. We branch on `.canSendDM` (not
      // `.tier == .free` directly) because DM-send is the primary value
      // prop the user is paying to unlock; the gate label stays
      // internally consistent across SendDirectMessageSheet + this view.
      if !tierGate.canSendDM {
        TeamFeedFreePreview(onUpgrade: { showUpgrade = true })
      } else {
        regularBody
      }
    }
    // T4 — per-callsite UpgradeModal sheet for the Free branch.
    .sheet(isPresented: $showUpgrade) {
      UpgradeModal(
        reason: .sendMessage,
        onDismiss: { showUpgrade = false },
        onSubmitEmail: { email in await submitToWaitlist(email) }
      )
    }
    // S6 closure-injection pattern — preserved 1:1 from OrganizationView.
    .sheet(item: $sendSheetRecipient) { r in
      SendDirectMessageSheet(
        recipient: r.member,
        initialKind: r.kind,
        onReauthorizeSlack: { @MainActor in
          await slackOAuth.connect()
        },
        resolveLinearAssignee: { @MainActor displayName in
          try? await linearUsersResolver.resolve(displayName: displayName)
        }
      )
    }
    .sheet(isPresented: $generateInvitePresented) {
      GenerateInviteSheet()
    }
    .sheet(isPresented: $createWorkspacePresented) {
      WorkspaceCreateSheet(
        onCreated: {
          workspaceReader.refresh()
          createWorkspacePresented = false
        },
        onCancel: { createWorkspacePresented = false }
      )
    }
    // Restore persisted filter selection + trigger initial feed load when
    // the active workspace changes. Lives on the page root (NOT inside
    // TeamFeedTab) so the feed stays warm regardless of selected hub tab.
    .task(id: activeWorkspaceStore.activeWorkspaceID) {
      // T4 — skip feed I/O when Free-tier preview is on screen; no
      // workspaces exist for a Free user, and the mockup is static data.
      guard tierGate.canSendDM else { return }
      // S7 Stage 6 fix C-I6 — prime the self-pubkey cache once; cheap
      // single filesystem read, then every directMessageCard render
      // reuses the @State value instead of re-reading the priv file.
      loadCachedSelfPubHex()
      guard let wid = activeWorkspaceStore.activeWorkspaceID else { return }
      feedFilterStore.loadForWorkspace(wid)
      await teamFeedReader.loadInitial(
        workspaceID: wid,
        filters: feedFilterStore.selected,
        selfPubkeyHex: selfPubkeyHex()
      )
      await loadCrossPostsForVisibleDMs()
    }
    // Re-fetch when filter chip selection changes.
    .onChange(of: feedFilterStore.selected) { _, newFilters in
      guard tierGate.canSendDM,
        let wid = activeWorkspaceStore.activeWorkspaceID
      else { return }
      Task {
        await teamFeedReader.refresh(
          workspaceID: wid,
          filters: newFilters,
          selfPubkeyHex: selfPubkeyHex()
        )
        await loadCrossPostsForVisibleDMs()
      }
    }
    // Live-tabs — mirror tables changed (realtime absorb / polling tick /
    // optimistic mark-done) while the feed is open. Warm refresh: TeamFeedReader
    // keeps current items rendered (isRefreshing path), so no loading flash and
    // no scroll jump. Overlapping refreshes self-correct: completion order wins
    // and the next bump re-reads fresh state.
    .onChange(of: liveSignals.teamFeedVersion) {
      guard tierGate.canSendDM,
        let wid = activeWorkspaceStore.activeWorkspaceID
      else { return }
      Task {
        await teamFeedReader.refresh(
          workspaceID: wid,
          filters: feedFilterStore.selected,
          selfPubkeyHex: selfPubkeyHex()
        )
        await loadCrossPostsForVisibleDMs()
      }
    }
  }

  /// Team-tier body — the regular feed surface. Extracted so the T4 Free
  /// branch lives in `body` cleanly.
  @ViewBuilder
  private var regularBody: some View {
    switch workspaceReader.state {
    case .loading:
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)

    case .empty:
      // workspaceReader.empty = no workspaces at all. Invite/share UI is
      // meaningless without a workspace — show create-workspace CTA instead.
      emptyStateNoWorkspace
        .frame(maxWidth: .infinity, maxHeight: .infinity)

    case .loaded(_, let active, let members):
      loadedContent(active: active, members: members)

    case .error(let message):
      errorContent(message: message)

    case .removedFromActiveWorkspace:
      // RootView preempts with RemovedFromTeamBanner.
      EmptyView()
    }
  }

  /// S7 Stage 6 fix C-I4 — batch-fetch cross-post log rows for all DM IDs
  /// in the currently-loaded feed. Realtime push covers newly-inserted rows
  /// at runtime; this is the cold-start path on app launch / workspace
  /// switch / filter change. Cheap when nothing new (server returns empty
  /// + reader caches the nil result to avoid retry storms — see
  /// CrossPostLogReader cache semantics).
  private func loadCrossPostsForVisibleDMs() async {
    guard case .loaded(let items, _) = teamFeedReader.state else { return }
    let dmIDs = items.compactMap { item -> String? in
      if case .directMessage(let row) = item { return row.messageID }
      return nil
    }
    guard !dmIDs.isEmpty else { return }
    await crossPostLogReader.loadForMessages(dmIDs)
  }

  // MARK: - G.2 Loaded content

  @ViewBuilder
  private func loadedContent(active: Workspace, members: [TeamMember]) -> some View {
    VStack(alignment: .leading, spacing: LeafSpace.md) {
      // Hub header: workspace mark + name + subtitle + Invite CTA (⌘N).
      WorkspaceHubHeader(
        active: active,
        memberCount: members.count,
        onInvite: { generateInvitePresented = true }
      )
      LeafTab(
        selection: $hubTab,
        tabs: TeamHubTab.allCases,
        label: { $0.title }
      )
      switch hubTab {
      case .chats:
        ChatsTab(
          active: active,
          members: members,
          selfPubkeyHex: { selfPubkeyHex() },
          onInvite: { generateInvitePresented = true },
          onSendDM: { member in
            if let member {
              sendSheetRecipient = SendRecipient(id: member.id, member: member)
            } else {
              sendSheetRecipient = nil
            }
          },
          onComposeStructured: { member, kind in
            sendSheetRecipient = SendRecipient(id: member.id, member: member, kind: kind)
          }
        )
      case .members:
        MembersTab(onTapMember: { member in
          sendSheetRecipient = SendRecipient(id: member.id, member: member)
        })
      case .settings:
        WorkspaceSettingsTab(active: active, members: members)
      }
    }
    .padding(LeafSpace.xxl)
    // Cap + center the whole column: on wide windows unconstrained rows pushed
    // timestamps far from their text and bubbles stretched unreadably.
    // The two-pane chat manager gets a wider cap than the single-column
    // Members/Settings tabs (list column + readable thread).
    .frame(
      maxWidth: hubTab == .chats
        ? LeafChatTokens.pageMaxWidth : LeafTeamFeedTokens.maxContentWidth,
      maxHeight: .infinity,
      alignment: .topLeading
    )
    .frame(maxWidth: .infinity, alignment: .top)
    // APNs deep-link to a message must land on the Feed tab regardless of
    // the currently-selected tab. `initial: true` covers the value being
    // set before this view (re)mounts; TeamFeedTab's own observer handles
    // the scroll-to + highlight once mounted.
    .onChange(of: windowState.pendingMessageID, initial: true) { _, id in
      if id != nil { hubTab = .chats }
    }
    // Explicit tab deep-link (e.g. join-request push → Members). Consumed
    // once: set the tab, clear the signal.
    .onChange(of: windowState.pendingHubTab, initial: true) { _, tab in
      if let tab {
        hubTab = tab
        windowState.pendingHubTab = nil
      }
    }
  }

  // MARK: - Empty / error states (workspace-level)

  /// State 0 — no workspace at all. Invite/share flows are meaningless without
  /// one; surface a create-workspace CTA that opens WorkspaceCreateSheet.
  /// Mirrors Sidebar's bottom-of-pane Add workspace / Join workspace rows but
  /// makes the primary CTA discoverable from the main content area.
  @ViewBuilder
  private var emptyStateNoWorkspace: some View {
    LeafEmptyState(
      icon: LeafIcons.nav.team,
      title: "No workspace yet",
      description: "Create your first workspace to invite teammates and start sharing work.",
      ctaTitle: "+ Create workspace",
      onCTA: { createWorkspacePresented = true }
    )
  }

  // MARK: - Error state

  @ViewBuilder
  private func errorContent(message: String) -> some View {
    LeafBanner(
      tone: .danger,
      title: "Couldn't load team",
      description: message,
      ctaTitle: "Try again",
      onCTA: { workspaceReader.refresh() }
    )
    .padding(LeafSpace.xxl)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  // MARK: - Helpers

  /// Best-effort self pubkey for TeamFeedReader selfPubkeyHex parameter.
  /// Falls back to "" — TeamFeedReader treats "" as "no self-exclusion" (graceful).
  ///
  /// S7 Stage 6 fix C-I6 — returns the cached @State value if loaded
  /// (loadCachedSelfPubHex sets it), else performs the IdentityService
  /// disk read once.
  ///
  /// S7 Stage 6 fix M3 — fallback path writes back into cachedSelfPubHex
  /// so a subsequent call doesn't re-attempt the disk read.
  private func selfPubkeyHex() -> String {
    if !cachedSelfPubHex.isEmpty { return cachedSelfPubHex }
    guard let key = try? IdentityService.ensureLocalIdentity(at: TeamKeystore.defaultRoot()) else {
      return ""
    }
    let hex = key.publicKey.rawRepresentation
      .map { String(format: "%02x", $0) }
      .joined()
    cachedSelfPubHex = hex
    return hex
  }
}
