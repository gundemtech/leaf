//
//  Sidebar.swift
//  Track 2 / D2 — three-group sidebar (LEAF / COLLABORATION / ACCOUNT) built on
//  LeafNavRow (D1 organism O3). Grouping lives exclusively here — each
//  group hardcodes its own WindowSection cases. Badge slot and shortcut slot
//  are empty (D2 baseline; D3+ may wire them up for Activity unread / etc).
//
//  Render pattern matches LeafNavRowPreview (TokensPreview) — flat VStack,
//  not List. macOS' List(selection:) with .listStyle(.sidebar) overlays
//  native sidebar selection chrome (saturated accent fill) on top of
//  LeafNavRow's own accent.subtle background — design-system intent is a
//  single source of truth for selection visuals: LeafNavRow.
//
//  Track 3 D2 — Connections nav row gains a small red attention dot when
//  GitHubScopesReader signals `.connectedScopeOutdated`. Track 3 D3 extends
//  the OR-condition to also fire when SlackScopesReader is outdated; Linear
//  scope reader will be wired up in Track 3 D4. Dot rendered as
//  `LeafDot(tone: .danger, size: .sm)` overlay topTrailing on the nav row
//  (LeafNavRow API stays untouched — `badge: Int?` is separate quantitative
//  semantics, the attention dot is a bool urgency cue, orthogonal).
//
//  Track 5 / S7 G.12 — removed `.organization` from COLLABORATION group;
//  replaced with a workspace switcher anchored at the sidebar bottom.
//  Layout: VStack { ScrollView (nav groups) + Spacer + switcher section }.
//  The inline list (LeafWorkspaceSwitcher) was later collapsed into
//  LeafWorkspacePicker — compact trigger row + popover — same callbacks.
//

import LeafCore
import SwiftUI

struct Sidebar: View {
  @Binding var selection: WindowSection

  @Environment(GitHubScopesReader.self) private var githubScopes
  @Environment(SlackScopesReader.self) private var slackScopes
  @Environment(WorkspaceReader.self) private var workspaceReader
  @Environment(ActiveWorkspaceStore.self) private var activeWorkspaceStore
  @Environment(DirectMessageInboxReader.self) private var inboxReader
  /// T4 — tier gate. Free-tier swaps `LeafWorkspacePicker` for an
  /// «Upgrade to add workspaces» row at the sidebar bottom.
  @Environment(TierGateReader.self) private var tierGate
  @Environment(\.submitToWaitlist) private var submitToWaitlist
  /// Track 6 — observer for deep-link / clipboard-probe `reader.fetch(...)`
  /// transitions out of `.idle`. Sidebar surfaces AcceptInviteSheet so an
  /// already-onboarded user can join a second workspace. Onboarding's own
  /// observer (`OnboardingView.swift`) is mutually exclusive — Onboarding
  /// is gated by `hasCompletedOnboarding` AppStorage and lives in the
  /// menu-bar popover scene, not the main Window where Sidebar renders.
  @Environment(InviteAcceptReader.self) private var inviteAcceptReader
  /// M027 invite-redesign — pendingInviteCode + joinRequestWaitingPresented
  /// driven by link clicks (InviteURLHandler) and JoinWorkspaceByCodeSheet
  /// post-Send dispatch (InviteURLHandler.handleCodePaste).
  @Environment(WindowState.self) private var windowState

  // Track-10 T1 — gates Analytics sidebar row. `@AppStorage` must be a View
  // instance property (NOT inside a computed prop closure) so SwiftUI binds
  // the property wrapper to the View invalidation graph and reflows the
  // sidebar when the toggle in Settings → Advanced flips.
  @AppStorage("leaf.ui.showAnalyticsSection") private var showAnalyticsSection: Bool = false

  @State private var leavePresented = false
  @State private var leaveTargetWorkspaceID: String?
  @State private var createWorkspacePresented = false
  /// T4 — per-callsite UpgradeModal flag for the Free-tier switcher row.
  @State private var showUpgrade = false
  /// S3 legacy AcceptInviteSheet — driven exclusively by
  /// `inviteAcceptReader.state` transitions when a legacy
  /// `leaf://invite/<uuid>?a=<adminpub>` URL is opened (back-compat for
  /// invites issued before M027 redesign). NOT wired to explicit-tap any
  /// more — that path uses `joinByCodePresented` (M027 paste-code).
  @State private var legacyAcceptInvitePresented = false
  /// M027 invite-redesign — explicit-tap path from the workspace switcher
  /// footer ("Join workspace" row). Opens JoinWorkspaceByCodeSheet with no
  /// pre-filled code. The same sheet is also opened automatically when
  /// `WindowState.pendingInviteCode` is set by InviteURLHandler on a
  /// `leaf://invite/<LEAF-XXXX-XXXX-XXXX>` link click — both paths share
  /// one sheet modifier via `joinByCodeBinding` below.
  @State private var joinByCodePresented = false
  @State private var profileHover = false
  /// Workspace picker dropdown — open state + geometry are hoisted here
  /// because the menu renders at the Sidebar root ZStack (an overlay on
  /// the trigger composites below later card siblings — profile row drew
  /// on top of the open menu).
  @State private var pickerOpen = false
  @State private var pickerTriggerFrame: CGRect = .zero
  @State private var switcherSectionHeight: CGFloat = 0

  private var leafGroupItems: [WindowSection] {
    showAnalyticsSection
      ? [.home, .activity, .analytics, .search, .askLeaf]
      : [.home, .activity, .search, .askLeaf]
  }

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      VStack(alignment: .leading, spacing: 0) {
        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading, spacing: LeafSpace.lg) {
            group(title: "LEAF", items: leafGroupItems)
            group(title: "COLLABORATION", items: [.team, .connections])
            // `.profile` left this group — it lives as a persistent row in
            // the bottom card next to the workspace picker (same target).
            group(title: "ACCOUNT", items: [.settings])
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, LeafSpace.md)
        }
        Spacer(minLength: 0)
        workspaceSwitcherSection
      }
      if pickerOpen {
        pickerDropdown
          // Anchored just above the bottom card: measured section height
          // already includes the card's own bottom inset, so adding the
          // gap lands the menu `dropdownGap` over the card's top edge.
          .padding(.bottom, switcherSectionHeight + LeafWorkspacePickerTokens.dropdownGap)
          .padding(.horizontal, LeafSpace.sm)
          .transition(
            .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom))
          )
      }
    }
    .leafAnimation(LeafMotion.spring.snappy, value: pickerOpen)
    .sheet(isPresented: $leavePresented) {
      if let wid = leaveTargetWorkspaceID,
        let workspace = workspacesByID[wid]
      {
        LeaveWorkspaceConfirmationModal(
          workspaceName: workspace.name,
          onConfirm: {
            // S7 Stage 6 fix C-C2 — call leaveWorkspace(workspaceID:)
            // directly. The earlier `setActive(wid) + leaveActiveWorkspace()`
            // shape relied on WorkspaceReader.state.active being read
            // *after* setActive, but setActive does not refresh the
            // Reader's state — leaveActiveWorkspace() would read the
            // previous active workspace and mark the *wrong* row left.
            workspaceReader.leaveWorkspace(workspaceID: wid)
            leavePresented = false
            leaveTargetWorkspaceID = nil
          },
          onCancel: {
            leavePresented = false
            leaveTargetWorkspaceID = nil
          }
        )
      }
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
    .sheet(isPresented: $showUpgrade) {
      UpgradeModal(
        reason: .createWorkspace,
        onDismiss: { showUpgrade = false },
        onSubmitEmail: { email in await submitToWaitlist(email) }
      )
    }
    // S3 legacy AcceptInviteSheet host — only deep-link / clipboard-probe
    // path now (`.onAppear` / `.onChange(of: inviteAcceptReader.state)` below).
    // Explicit-tap "Join workspace" no longer routes here — see
    // `joinByCodePresented` for the M027 paste-code path.
    .sheet(isPresented: $legacyAcceptInvitePresented) {
      AcceptInviteSheet()
    }
    // M027 invite-redesign — unified JoinWorkspaceByCodeSheet host. Triggers:
    //  (a) explicit user tap on the "Join workspace" switcher footer row
    //      (sets `joinByCodePresented = true`)
    //  (b) link-click via `leaf://invite/<LEAF-XXXX-XXXX-XXXX>` →
    //      InviteURLHandler sets `WindowState.pendingInviteCode = code` →
    //      sheet opens pre-filled at `.enterName` step
    .sheet(
      isPresented: Binding(
        get: { joinByCodePresented || windowState.pendingInviteCode != nil },
        set: { newValue in
          if !newValue {
            joinByCodePresented = false
            windowState.pendingInviteCode = nil
          }
        }
      )
    ) {
      JoinWorkspaceByCodeSheet()
    }
    // M027 invite-redesign — after Send Request, the waiting card polls
    // own request status (30s) until terminal state.
    .sheet(isPresented: Bindable(windowState).joinRequestWaitingPresented) {
      JoinRequestWaitingCard()
    }
    .onAppear {
      // Catch state already non-`.idle` when Sidebar first appears —
      // e.g. user launched app via a `leaf://invite/...` URL and the
      // `.onOpenURL` handler in LeafApp.swift fired `reader.fetch`
      // before Sidebar was mounted.
      if shouldOpenAcceptSheet(for: inviteAcceptReader.state) {
        legacyAcceptInvitePresented = true
      }
    }
    .onChange(of: inviteAcceptReader.state) { _, newState in
      // Open-only — never auto-dismiss. Sheet's Discard / Done /
      // Close paths call `reader.reset()` which lands here as
      // `.idle`; we let SwiftUI dismiss the sheet naturally when
      // the user taps those buttons (sheet's `dismiss()` flips
      // `legacyAcceptInvitePresented` back to `false`).
      if shouldOpenAcceptSheet(for: newState), !legacyAcceptInvitePresented {
        legacyAcceptInvitePresented = true
      }
    }
  }

  /// True for any in-flight or terminal-non-idle state — auto-surface the
  /// sheet so the user sees what's happening. `.idle` is the only state
  /// that should NOT auto-open.
  private func shouldOpenAcceptSheet(for state: InviteAcceptReader.State) -> Bool {
    switch state {
    case .idle: return false
    case .previewing, .joining, .otpPrompt, .joined, .error: return true
    }
  }

  // MARK: - Workspace Switcher

  /// Bottom card: workspace picker row (or Free-tier upgrade row) +
  /// divider + persistent profile row. Profile moved here from the
  /// ACCOUNT nav group so "who am I" is always visible at the bottom.
  @ViewBuilder
  private var workspaceSwitcherSection: some View {
    VStack(alignment: .leading, spacing: LeafSpace.xxs) {
      // T4 — Free-tier: replace LeafWorkspacePicker with a single
      // «Upgrade to add workspaces» row. Free user has no workspaces, so
      // there's nothing to switch *to* anyway — the row serves both as
      // empty state AND the upgrade CTA in one strike.
      if !tierGate.canCreateWorkspace {
        freeStateSwitcherRow
      } else {
        teamStateSwitcher
      }
      Divider()
        .opacity(LeafWorkspacePickerTokens.dividerOpacity)
      profileRow
    }
    .padding(LeafWorkspacePickerTokens.sectionPadding)
    .background(
      RoundedRectangle(
        cornerRadius: LeafWorkspacePickerTokens.cardCornerRadius,
        style: .continuous
      )
      .fill(LeafColor.surface.inset)
    )
    .padding(.horizontal, LeafSpace.sm)
    .padding(.bottom, LeafSpace.sm)
    .background(
      GeometryReader { geo in
        Color.clear
          .onAppear { switcherSectionHeight = geo.size.height }
          .onChange(of: geo.size.height) { _, new in
            switcherSectionHeight = new
          }
      }
    )
  }

  /// Workspaces shown by both the trigger row and the dropdown list.
  private var sortedWorkspaces: [Workspace] {
    let workspaces: [Workspace] = {
      if case .loaded(let ws, _, _) = workspaceReader.state { return ws }
      return []
    }()
    return
      workspaces
      .filter { $0.leftAt == nil }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  @ViewBuilder
  private var teamStateSwitcher: some View {
    LeafWorkspacePicker(
      workspaces: sortedWorkspaces,
      activeWorkspaceID: activeWorkspaceStore.activeWorkspaceID,
      unreadCounts: inboxReader.unreadCountByWorkspace,
      isOpen: $pickerOpen,
      triggerFrame: $pickerTriggerFrame
    )
  }

  /// Rendered at the body ZStack root — see `pickerOpen` declaration.
  private var pickerDropdown: some View {
    LeafWorkspacePickerDropdown(
      workspaces: sortedWorkspaces,
      activeWorkspaceID: activeWorkspaceStore.activeWorkspaceID,
      unreadCounts: inboxReader.unreadCountByWorkspace,
      triggerFrame: pickerTriggerFrame,
      // S7 Stage 6 fix C-C3 — route through switchActive(to:) so the
      // Reader's state.active is refreshed alongside the store; otherwise
      // TeamView renders the previous workspace's name and members
      // because state.active is only re-resolved on refresh().
      onSelect: { wid in workspaceReader.switchActive(to: wid) },
      onAddNew: { createWorkspacePresented = true },
      onJoin: { joinByCodePresented = true },
      onLeave: { wid in
        leaveTargetWorkspaceID = wid
        leavePresented = true
      },
      onMarkAllRead: { _ in
        // TODO: Phase v1.1 — bulk mark-read
        // Wire: inboxReader.markAllReadForWorkspace(wid)
      },
      onDismiss: { pickerOpen = false }
    )
  }

  /// T4 — Free-tier switcher row. Sits in the same bottom-card slot the
  /// LeafWorkspacePicker trigger occupies on Team tier, matching its row
  /// height so the card feels continuous between tiers.
  @ViewBuilder
  private var freeStateSwitcherRow: some View {
    Button {
      showUpgrade = true
    } label: {
      HStack(spacing: LeafSpace.sm) {
        Image(systemName: "lock.fill")
          .font(.system(size: 14))
          .foregroundStyle(LeafColor.status.warning)
        Text("Upgrade to add workspaces")
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.text.primary)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, LeafSpace.sm)
      .frame(height: LeafWorkspacePickerTokens.triggerHeight)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
  }

  // MARK: - Profile row

  /// Persistent "who am I" row at the card bottom. Same identity source
  /// as ProfileView's header (`NSFullUserName()`); circle = person (the
  /// picker's workspace marks are squares). Tap navigates to Profile.
  private var profileRow: some View {
    Button {
      selection = .profile
    } label: {
      HStack(spacing: LeafSpace.sm) {
        Circle()
          .fill(profileTint.gradient)
          .frame(
            width: LeafWorkspacePickerTokens.triggerMarkSize,
            height: LeafWorkspacePickerTokens.triggerMarkSize
          )
          .overlay(
            Text(TeamNRowComposer.initials(profileName))
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.white)
          )
          .accessibilityHidden(true)
        Text(profileName)
          .font(LeafType.body.regular)
          .foregroundStyle(LeafColor.text.primary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, LeafSpace.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: LeafWorkspacePickerTokens.triggerHeight)
      .background(
        RoundedRectangle(
          cornerRadius: LeafWorkspacePickerTokens.rowCornerRadius,
          style: .continuous
        )
        .fill(profileRowFill)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { profileHover = $0 }
    .leafAnimation(LeafMotion.spring.snappy, value: profileHover)
  }

  private var profileName: String {
    let n = NSFullUserName().trimmingCharacters(in: .whitespaces)
    return n.isEmpty ? "Local user" : n
  }

  private var profileTint: Color {
    // Same palette + index derivation as TeamNBlock avatars.
    let palette: [Color] = [
      LeafColor.accent.primary,
      LeafColor.accent.emphasis,
      LeafColor.status.info,
      LeafColor.status.danger,
      LeafColor.text.secondary,
    ]
    let idx = TeamNRowComposer.paletteIndex(memberID: profileName, paletteCount: palette.count)
    return palette[idx]
  }

  private var profileRowFill: Color {
    if selection == .profile { return LeafColor.accent.subtle }
    if profileHover { return LeafColor.surface.raised }
    return Color.clear
  }

  // MARK: - Helpers

  /// True when any wired provider scope-status reader signals outdated.
  /// D2 wires only GitHub; D3 adds Slack via OR-condition; Track 3 D4
  /// generalizes per-provider scope status.
  private var connectionsNeedsAttention: Bool {
    if case .connectedScopeOutdated = githubScopes.state { return true }
    if case .connectedScopeOutdated = slackScopes.state { return true }
    return false
  }

  private var workspacesByID: [String: Workspace] {
    let workspaces: [Workspace] = {
      if case .loaded(let ws, _, _) = workspaceReader.state { return ws }
      return []
    }()
    return Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
  }

  @ViewBuilder
  private func group(title: String, items: [WindowSection]) -> some View {
    VStack(alignment: .leading, spacing: LeafSpace.xs) {
      Text(title)
        .leafSectionLabel()
        .foregroundStyle(LeafColor.text.tertiary)
        .padding(.horizontal, LeafSpace.md)

      VStack(alignment: .leading, spacing: LeafSpace.xxs) {
        ForEach(items) { item in
          LeafNavRow(
            icon: item.iconIsSystem ? .system(item.icon) : .asset(item.icon),
            title: item.title,
            isSelected: Binding(
              get: { selection == item },
              set: { if $0 { selection = item } }
            ),
            onTap: { selection = item }
          )
          .overlay(alignment: .topTrailing) {
            if item == .connections, connectionsNeedsAttention {
              LeafDot(tone: .danger, size: .sm)
                .padding(LeafSpace.sm)
                .accessibilityLabel("Attention required")
            }
          }
        }
      }
    }
  }
}
