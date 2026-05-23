//
//  TeamView.swift
//  Track 5 / S7 G.2-G.11 — Unified Team feed layout.
//
//  Replaces Track 2 / D3 adaptive-grid-of-members with the new feed structure:
//
//    ┌── toolbar: name · N members · [+ Send] ⌘N ───────────────────────────┐
//    ├── members pill-row (horizontal scroll) ────────────────────────────────┤
//    ├── LeafFilterChips (All · DM · Tasks · Decisions · Blockers · More…) ───┤
//    └── feed body: LazyVStack dispatch (G.6-G.11) ───────────────────────────┘
//
//  Feed dispatch (G.6):
//    .loading     → ProgressView
//    .error(msg)  → LeafBanner .danger
//    .loaded(items, hasMore):
//       items.isEmpty → 3-state emptyState (G.10)
//       items.nonEmpty → ScrollView + LazyVStack + cardView dispatch (G.7/G.8)
//                        + pagination sentinel when hasMore (G.11)
//
//  cardView dispatch (G.6):
//    .directMessage  → LeafMessageCard (G.7) with auto-mark-read + actions
//    .teamEvent      → LeafFeedRow single (G.8)
//    .grouped        → LeafFeedRow.grouped collapsible (G.8)
//
//  Empty states (G.10):
//    State 1 — 0 or 1 member (only self): invite CTA
//    State 2 — members joined, no activity: send first message CTA
//    State 3 — filters narrow: clear filters CTA
//
//  Attachment resolution (G.9): per-row async cache via @State dict keyed by
//  externalRef. Resolver is a lazily-noop-defaulted AttachmentMetadataResolver;
//  Phase H composition root replaces it with a live DB-backed resolver.
//
//  Environment dependencies:
//    Already wired (S2/S4/S5/S6):
//      WorkspaceReader, ActiveWorkspaceStore, DirectMessageInboxReader,
//      TeamEventMirrorReader, SlackOAuthService, \.linearUsersResolver
//    Phase H wires these new ones:
//      TeamFeedReader, FeedFilterStore, CrossPostLogReader
//
//  Phase H gap: @Environment(TeamFeedReader.self) and
//  @Environment(FeedFilterStore.self) will crash at runtime (not compile-time)
//  if not injected. Phase H composition root wires them. Until then the app
//  must not navigate to TeamView in a test run without the H injection.
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
  @Environment(DirectMessageInboxReader.self) private var inboxReader
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

  // MARK: - Phase H: new environment readers
  //
  // These will be injected by Phase H composition root.
  // See LeafApp.swift — Phase H adds:
  //   .environment(teamFeedReader)
  //   .environment(feedFilterStore)
  // Until Phase H ships, navigating to TeamView crashes with:
  //   "No Observable of type TeamFeedReader found. A View.environment(_:) for
  //    TeamFeedReader may be missing as an ancestor of this view."

  @Environment(TeamFeedReader.self) private var teamFeedReader
  @Environment(FeedFilterStore.self) private var feedFilterStore
  // S7 Stage 6 fix C-I4 — Phase H wired this reader into LeafApp's
  // composition root but the consumer side here remained `let crossPosts =
  // []`. Inject + read in directMessageCard so cross-post badges actually
  // render (OQ-S7-1).
  @Environment(CrossPostLogReader.self) private var crossPostLogReader

  // MARK: - Phase H.6: APNs deep-link target
  //
  // LeafAppDelegate.userNotificationCenter(didReceive:) populates
  // `windowState.pendingMessageID` after the user clicks a notification.
  // We observe via .onChange and scroll-to + transient highlight pulse.

  @Environment(WindowState.self) private var windowState

  // MARK: - Phase H.3 attachment resolver (replaces local @State noop)
  //
  // Composition root wires `AttachmentMetadataResolver` (DB-backed) via
  // custom EnvironmentKey. Falls back to nil when not yet wired — G.9
  // already gracefully degrades to label-only attachment chips.

  @Environment(\.attachmentMetadataResolver) private var injectedResolver

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
  }

  // MARK: - G.8 grouped expand state

  /// Set of group IDs currently expanded in the feed. A group ID is:
  /// "grouped-<source.rawValue>-<senderPubkeyHex>-<spanStartMs>"
  @State private var expandedGroups: Set<String> = []

  // MARK: - G.9 Attachment metadata cache

  /// Keyed by `DirectMessageAttachment.externalRef`. Populated lazily via
  /// `.task(id: externalRef)` on each DM card. Phase H wires a live resolver;
  /// until then every resolve() call returns nil (graceful: card renders without
  /// attachment metadata embed but attachment label is still shown).
  @State private var attachmentMetadataCache: [String: AttachmentMetadata] = [:]

  /// Phase H landed: resolver is now injected via
  /// `@Environment(\.attachmentMetadataResolver)` (see above).
  /// Retained @State exists only as a fallback when the EnvironmentKey
  /// returns nil (e.g., unit-test snapshots or DB open failures).
  @State private var attachmentMetadataResolver: AttachmentMetadataResolver? = nil

  // MARK: - G.6 / H.6 transient scroll-to highlight

  /// Message id that is currently being highlighted as the deep-link target.
  /// Cleared via a Task.sleep timer ~2s after scroll-to fires.
  @State private var highlightedMessageID: String? = nil

  /// S7 Stage 6 fix C-I6 — cached self-pubkey hex. Loaded once via
  /// `loadCachedSelfPubHex()` on `.onAppear`; consulted by `selfPubkeyHex()`.
  /// Replaces a per-render call to `IdentityService.ensureLocalIdentity`
  /// (filesystem I/O on the main thread inside the LazyVStack body). Empty
  /// string == "not yet loaded" / "no identity" — TeamFeedReader treats
  /// that as no self-exclusion (graceful).
  @State private var cachedSelfPubHex: String = ""

  /// T4 — per-callsite UpgradeModal flag for the Free-tier preview branch.
  /// `TeamFeedFreePreview.onUpgrade` flips this; UpgradeModal lives in the
  /// same `.sheet(isPresented: $showUpgrade)` modifier as the rest of the
  /// existing TeamView sheets.
  @State private var showUpgrade: Bool = false

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
    // the active workspace changes.
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
      // G.3 — Toolbar: workspace name + member count + [+ Send] button
      toolbar(active: active, memberCount: members.count)
      // G.4 — Horizontal members pill-row (tap opens SendDirectMessageSheet)
      membersPillRow(members: members)
      // G.5 — Filter chips (All / DM / Open Tasks / Decisions / Blockers / More…)
      FeedFilterChipsBindable(store: feedFilterStore)
      // G.6-G.11 — Feed body: LazyVStack + card dispatch + empty states + pagination
      feedBody(workspaceID: active.id, members: members)
    }
    .padding(LeafSpace.xxl)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  // MARK: - G.3 Toolbar

  @ViewBuilder
  private func toolbar(active: Workspace, memberCount: Int) -> some View {
    HStack(spacing: LeafSpace.md) {
      VStack(alignment: .leading, spacing: 2) {
        Text(active.name)
          .font(LeafType.title.medium)
          .foregroundStyle(LeafColor.text.primary)
          .lineLimit(1)
        Text("\(memberCount) member\(memberCount == 1 ? "" : "s")")
          .font(LeafType.caption)
          .foregroundStyle(LeafColor.text.tertiary)
      }
      Spacer(minLength: 0)
      // G.3 — Invite CTA. Round 8 — user wants all create/new/generate/
      // invite CTAs styled identically (primary .md) across the app for
      // visual consistency; the round-4 secondary-when-populated variant
      // was overruled.
      LeafButton("+ Invite teammate", variant: .primary, size: .md) {
        generateInvitePresented = true
      }
      .keyboardShortcut("n", modifiers: .command)
    }
  }

  // MARK: - G.4 Members pill-row

  @ViewBuilder
  private func membersPillRow(members: [TeamMember]) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: LeafSpace.sm) {
        ForEach(members, id: \.id) { member in
          memberPill(member)
        }
      }
    }
  }

  @ViewBuilder
  private func memberPill(_ member: TeamMember) -> some View {
    Button {
      sendSheetRecipient = SendRecipient(id: member.id, member: member)
    } label: {
      HStack(spacing: LeafSpace.xs) {
        LeafAvatar(initials: initials(for: member.displayName), size: .sm)
        Text(member.displayName)
          .font(LeafType.caption)
          .foregroundStyle(LeafColor.text.primary)
          .lineLimit(1)
      }
      .padding(.horizontal, LeafSpace.sm)
      .padding(.vertical, LeafSpace.xs)
      .background(LeafColor.surface.raised)
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
  }

  // MARK: - G.6 Feed body: LazyVStack + card dispatch

  @ViewBuilder
  private func feedBody(workspaceID: String, members: [TeamMember]) -> some View {
    switch teamFeedReader.state {
    case .loading:
      VStack {
        Spacer(minLength: 0)
        ProgressView()
          .frame(maxWidth: .infinity, alignment: .center)
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

    case .error(let msg):
      LeafBanner(
        tone: .danger,
        title: "Feed error",
        description: msg,
        onDismiss: nil
      )

    case .loaded(let items, let hasMore):
      if items.isEmpty {
        emptyState(forMembers: members.count)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        // H.6 — ScrollViewReader gives us scrollTo(_:anchor:) so the
        // APNs deep-link can jump to the matched message cell. The
        // proxy.scrollTo(...) call must run inside `.onChange` which
        // is wired below via a binding to `windowState.pendingMessageID`.
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: LeafSpace.sm) {
              ForEach(items) { item in
                cardView(for: item, members: members)
                  .id(item.id)
              }
              if hasMore {
                paginationSentinel(workspaceID: workspaceID)
              }
            }
            .padding(.bottom, LeafSpace.md)
          }
          // H.6 — observe deep-link target and scroll/highlight.
          .onChange(of: windowState.pendingMessageID) { _, newID in
            guard let messageID = newID else { return }
            withAnimation {
              proxy.scrollTo(messageID, anchor: .center)
            }
            highlightedMessageID = messageID
            Task {
              try? await Task.sleep(nanoseconds: 2_000_000_000)
              await MainActor.run {
                if highlightedMessageID == messageID {
                  highlightedMessageID = nil
                }
                if windowState.pendingMessageID == messageID {
                  windowState.pendingMessageID = nil
                  windowState.pendingWorkspaceID = nil
                }
              }
            }
          }
          // Track 5 / S8 T6 — observe focusReplyField raised by the
          // APNs `dm.reply` action handler in LeafAppDelegate. When
          // set true:
          //   • scroll to the deep-linked message (pendingMessageID
          //     was already set by the same handler call, so this
          //     supplements the pendingMessageID observer above —
          //     we still call scrollTo here defensively in case the
          //     observer above fired before this one).
          //   • Signal reply-focus intent. The inline reply
          //     textfield itself ships in Track 6 (S7 deferred inline
          //     reply per spec note). Until that lands, this is pure
          //     state plumbing — the observer fires, the flag clears,
          //     and the existing scroll/highlight pulse provides the
          //     visible deep-link acknowledgement. Once the inline
          //     reply UI lands, `@FocusState` binding here will
          //     hand focus to the textfield.
          .onChange(of: windowState.focusReplyField) { _, newValue in
            guard newValue, let messageID = windowState.pendingMessageID else {
              return
            }
            withAnimation {
              proxy.scrollTo(messageID, anchor: .center)
            }
            // Clear the transient signal — consumer (future inline
            // reply UI) will read it before this clear via the
            // same .onChange cycle. The pendingMessageID stays
            // set; the H.6 observer above clears it on its own 2s
            // timer alongside highlightedMessageID.
            windowState.focusReplyField = false
          }
        }
      }
    }
  }

  // MARK: - G.6 cardView dispatch

  @ViewBuilder
  private func cardView(for item: FeedItem, members: [TeamMember]) -> some View {
    switch item {
    case .directMessage(let row):
      directMessageCard(row: row)
    case .teamEvent(let event):
      teamEventRow(event: event)
    case .grouped(let kind, let sender, let count, let spanStart, let spanEnd, let expandedItems):
      groupedRow(
        kind: kind,
        sender: sender,
        count: count,
        spanStart: spanStart,
        spanEnd: spanEnd,
        items: expandedItems
      )
    }
  }

  // MARK: - G.7 directMessageCard

  @ViewBuilder
  private func directMessageCard(row: DirectMessageMirrorRow) -> some View {
    let isOutbound = row.senderPubkeyHex == selfPubkeyHex()
    let direction: MessageDirectionUI = isOutbound ? .outbound : .inbound
    // S7 Stage 6 fix C-I4 — read CrossPostLogReader for the badges. The
    // reader is populated by (a) Realtime POSTGRES_CHANGES push via
    // LeafRealtimeService → absorbRealtimePush, or (b) explicit
    // loadForMessages batch fetch (kicked from the feed-loaded .task
    // below). Empty array when the message has no cross-posts (most DMs).
    let crossPosts = crossPostLogReader.crossPosts(for: row.messageID)
    let cachedMeta = row.attachment.flatMap { attachmentMetadataCache[$0.externalRef] }
    let actions = computeActions(for: row, isOutbound: isOutbound)

    LeafMessageCard(
      row: row,
      direction: direction,
      crossPosts: crossPosts,
      attachmentMetadata: cachedMeta,
      actions: actions,
      onAction: { handleAction($0, for: row) },
      onAppear: {
        Task { await markReadIfNeeded(row: row, isOutbound: isOutbound) }
      }
    )
    .task(id: row.attachment?.externalRef) {
      await resolveAttachment(for: row)
    }
  }

  private func computeActions(
    for row: DirectMessageMirrorRow,
    isOutbound: Bool
  ) -> [MessageAction] {
    var actions: [MessageAction] = []
    if !isOutbound {
      if row.readAtMs == nil { actions.append(.markRead) }
      actions.append(.reply)
      if row.kind == .task && row.doneAtMs == nil { actions.append(.markDone) }
    }
    actions.append(.copyText)
    if row.attachment != nil { actions.append(.viewOriginal) }
    return actions
  }

  private func handleAction(_ action: MessageAction, for row: DirectMessageMirrorRow) {
    switch action {
    case .markRead:
      Task { await inboxReader.markRead(messageID: row.messageID) }
    case .markUnread:
      // Phase v1.1 carry-over — unread write not yet in service layer.
      break
    case .reply:
      // Phase v1.1 — open Send sheet pre-filled with reply_to.
      // Until then, open a fresh send sheet toward the sender.
      sendSheetRecipient = nil  // dismiss current if any
      // We don't have a TeamMember for the sender here; defer to Phase H
      // member-lookup wiring which provides members via workspaceReader.
      break
    case .markDone:
      Task { await inboxReader.markDone(messageID: row.messageID) }
    case .copyText:
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(row.body, forType: .string)
    case .viewOriginal:
      if let att = row.attachment,
        let url = composeURL(forExternalRef: att.externalRef, kind: att.kind)
      {
        NSWorkspace.shared.open(url)
      }
    }
  }

  private func markReadIfNeeded(row: DirectMessageMirrorRow, isOutbound: Bool) async {
    guard !isOutbound, row.readAtMs == nil else { return }
    // LeafMessageCard schedules a 1500ms timer before calling onAppear.
    // When this callback fires the message has been visible long enough.
    await inboxReader.markRead(messageID: row.messageID)
  }

  /// Best-effort URL composer for a DM attachment external ref.
  private func composeURL(forExternalRef ref: String, kind: String) -> URL? {
    if kind.hasPrefix("github") {
      // Format: "owner/repo#N" or plain number.
      return URL(string: "https://github.com/\(ref.replacingOccurrences(of: "#", with: "/pull/"))")
    }
    if kind.hasPrefix("linear") {
      return URL(string: "https://linear.app/issue/\(ref)")
    }
    if kind.hasPrefix("slack") {
      // Format: "channel_id/thread_ts"
      let parts = ref.split(separator: "/", maxSplits: 1)
      if parts.count == 2 {
        let chan = String(parts[0])
        let ts = String(parts[1]).replacingOccurrences(of: ".", with: "")
        return URL(string: "https://slack.com/archives/\(chan)/p\(ts)")
      }
    }
    return nil
  }

  // MARK: - G.9 Attachment resolution

  private func resolveAttachment(for row: DirectMessageMirrorRow) async {
    guard let att = row.attachment else { return }
    let ref = att.externalRef
    if attachmentMetadataCache[ref] != nil { return }  // already cached
    // H.3 — prefer env-injected DB-backed resolver; @State fallback survives
    // for unit-test snapshots / DB-open failures (degrades to label-only).
    guard let resolver = injectedResolver ?? attachmentMetadataResolver else { return }
    let provider = providerFromKind(att.kind)
    let metadata = await resolver.resolve(provider: provider, externalRef: ref)
    await MainActor.run {
      if let metadata { attachmentMetadataCache[ref] = metadata }
    }
  }

  private func providerFromKind(_ kind: String) -> AttachmentProvider {
    if kind.hasPrefix("github") { return .github }
    if kind.hasPrefix("linear") { return .linear }
    if kind.hasPrefix("slack") { return .slack }
    return .github
  }

  // MARK: - G.8 teamEventRow + groupedRow

  @ViewBuilder
  private func teamEventRow(event: RenderedTeamEvent) -> some View {
    LeafFeedRow(
      event: event, attachmentMetadata: nil,
      onTap: {
        // Phase v1.1 — tap → open detail view or external URL.
      })
  }

  @ViewBuilder
  private func groupedRow(
    kind: String,
    sender: TeamMember,
    count: Int,
    spanStart: Int64,
    spanEnd: Int64,
    items: [RenderedTeamEvent]
  ) -> some View {
    // S8 T11: FeedItem.grouped.kind is now the raw event_kind String per
    // S7 spec §11.0:575. Group ID must mirror FeedItem.id format exactly
    // — "grouped-<raw_event_kind>-<sender_pubkey>-<spanStartMs>" — or
    // expand/collapse state keyed off this ID will diverge from the
    // identity used by SwiftUI ForEach.
    let groupID = "grouped-\(kind)-\(sender.pubkeyHex)-\(spanStart)"
    let isExpanded = Binding<Bool>(
      get: { expandedGroups.contains(groupID) },
      set: { newValue in
        if newValue { expandedGroups.insert(groupID) } else { expandedGroups.remove(groupID) }
      }
    )
    // Derive ShareSource from raw event_kind for LeafFeedRow visual
    // styling (icon + pluralized aggregate text). The classifier is the
    // single source of truth for kind→source mapping; unmappable kinds
    // (e.g. future detector kinds not yet wired) degrade to
    // .rawGitHubActivity which renders as a neutral "GitHub activity"
    // row rather than crashing. This is a display-only fallback —
    // grouping semantics (per-raw-kind bursts) are unaffected.
    let displaySource = ShareSourceClassifier().classify(eventKind: kind) ?? .rawGitHubActivity
    LeafFeedRow.grouped(
      source: displaySource,
      senderDisplayName: sender.displayName,
      senderPubkeyHex: sender.pubkeyHex,
      count: count,
      spanStartMs: spanStart,
      spanEndMs: spanEnd,
      expandedItems: items,
      isExpanded: isExpanded
    )
  }

  // MARK: - G.10 Three explicit empty states

  @ViewBuilder
  private func emptyState(forMembers memberCount: Int) -> some View {
    if memberCount <= 1 {
      emptyStateNoTeam
    } else if !feedFilterStore.selected.contains(.all) {
      emptyStateFiltered
    } else {
      emptyStateAwaitingActivity(memberCount: memberCount)
    }
  }

  /// State 1 — fresh workspace or no workspace at all (only self or nobody).
  @ViewBuilder
  private var emptyStateNoTeam: some View {
    LeafEmptyState(
      icon: LeafIcons.nav.team,
      title: "It's quiet here",
      description: "Invite teammates to start sharing work together.",
      ctaTitle: "+ Invite teammate",
      onCTA: { generateInvitePresented = true }
    )
  }

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

  /// State 2 — members joined but no activity yet (all filters selected).
  @ViewBuilder
  private func emptyStateAwaitingActivity(memberCount: Int) -> some View {
    let membersLabel = memberCount == 2 ? "1 teammate" : "\(memberCount - 1) teammates"
    LeafEmptyState(
      icon: LeafIcons.comm.message,
      title: "\(membersLabel) here",
      description: "Activity will appear as your team shares work. Send the first message.",
      ctaTitle: "+ Send first message",
      onCTA: { sendSheetRecipient = nil }  // Phase H: open recipient-picker
    )
  }

  /// State 3 — active filters yield no results.
  @ViewBuilder
  private var emptyStateFiltered: some View {
    // LeafEmptyState takes an Asset Catalog name; use folderEmpty as "no results" icon.
    // A dedicated filter icon (leaf-nav-filter) can replace this in Phase H Theme pass.
    LeafEmptyState(
      icon: LeafIcons.object.folderEmpty,
      title: "No matches",
      description: "Try clearing filters or selecting different sources.",
      ctaTitle: "Clear filters",
      onCTA: { feedFilterStore.clearAll() }
    )
  }

  // MARK: - G.11 Pagination sentinel

  @ViewBuilder
  private func paginationSentinel(workspaceID: String) -> some View {
    HStack(spacing: LeafSpace.sm) {
      ProgressView()
        .scaleEffect(0.7)
      Text("Loading older…")
        .font(LeafType.caption)
        .foregroundStyle(LeafColor.text.tertiary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, LeafSpace.md)
    .task {
      await loadOlderIfNeeded(workspaceID: workspaceID)
    }
  }

  private func loadOlderIfNeeded(workspaceID: String) async {
    guard case .loaded(let items, let hasMore) = teamFeedReader.state, hasMore else { return }
    guard let oldestTs = items.last?.timestamp else { return }
    await teamFeedReader.loadOlder(
      workspaceID: workspaceID,
      filters: feedFilterStore.selected,
      selfPubkeyHex: selfPubkeyHex(),
      before: oldestTs
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

  private func initials(for name: String) -> String {
    let parts = name.split(separator: " ").prefix(2)
      .compactMap { $0.first.map(String.init) }
      .joined()
      .uppercased()
    return parts.isEmpty ? "?" : parts
  }

  /// Best-effort self pubkey for TeamFeedReader selfPubkeyHex parameter.
  /// Falls back to "" — TeamFeedReader treats "" as "no self-exclusion" (graceful).
  ///
  /// S7 Stage 6 fix C-I6 — returns the cached @State value if loaded
  /// (loadSelfPubHex sets it on .onAppear), else performs the
  /// IdentityService disk read once. The earlier impl did the disk read on
  /// every call — including N times per LazyVStack render pass through
  /// directMessageCard. With long DM feeds this manifested as visible UI
  /// jank on scroll. Matches the WorkspaceSettingsSection.loadMyPubHex
  /// + WorkspaceMembersAdminList pattern.
  ///
  /// S7 Stage 6 fix M3 — fallback path writes back into cachedSelfPubHex
  /// so a subsequent call doesn't re-attempt the disk read. Without this,
  /// if loadCachedSelfPubHex() failed during .task (identity not yet
  /// provisioned, race against keystore setup, etc.), every directMessageCard
  /// render would retry the disk read until the next .task fires.
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

// MARK: - FeedFilterChipsBindable

/// @Observable bridge: provides a manual `Binding<Set<FeedFilter>>` to `LeafFilterChips`
/// that routes write-backs through `FeedFilterStore.applySelection(_:)` to ensure
/// persistence is triggered. `@Bindable` alone generates a setter that writes directly
/// to `store.selected`, bypassing persistence — this wrapper closes that gap.
@MainActor
private struct FeedFilterChipsBindable: View {
  var store: FeedFilterStore

  var body: some View {
    LeafFilterChips(
      visibleFilters: [.all, .directMessages, .openTasks, .decisions, .blockers],
      popoverFilters: ShareSource.allCases.map { .shareSource($0) },
      selected: Binding(
        get: { store.selected },
        set: { store.applySelection($0) }
      )
    )
  }
}
