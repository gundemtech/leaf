//
//  TeamFeedTab.swift
//  Team → Workspace Hub — Feed tab. Verbatim extraction of the feed
//  surface from TeamView (Track 5 / S7 G.5–G.11): filter chips + feed
//  dispatch + card views + empty states + pagination + APNs deep-link
//  scroll/highlight. NO visual or behavioral redesign — relocation only.
//
//  Data-loading ownership stays on TeamView: the root
//  `.task(id: activeWorkspaceID)` + `.onChange(feedFilterStore.selected)`
//  live there so the feed keeps loading/refreshing while the user sits on
//  the Members/Settings tabs (TeamFeedReader holds state independent of
//  mount; unread badges + deep links depend on it). Likewise
//  `selfPubkeyHex()` caching stays on TeamView (the root task needs it) —
//  this tab receives it as a closure.
//
//  Deep-link observers use `initial: true` — the value can be set before
//  this tab mounts (notification clicked while another tab was selected);
//  the plain .onChange shape silently dropped that case.
//

import LeafCore
import SwiftUI

struct TeamFeedTab: View {
  let active: Workspace
  let members: [TeamMember]
  /// Cached-self-pubkey accessor owned by TeamView (S7 Stage 6 fix C-I6).
  let selfPubkeyHex: () -> String
  /// Opens GenerateInviteSheet (empty-state CTA).
  let onInvite: () -> Void
  /// Send-sheet intent. `nil` recipient preserves today's no-op semantics
  /// of the "Send first message" CTA + `.reply` action (Phase H
  /// recipient-picker / Phase v1.1 reply wiring lands later).
  let onSendDM: (TeamMember?) -> Void

  @Environment(TeamFeedReader.self) private var teamFeedReader
  @Environment(FeedFilterStore.self) private var feedFilterStore
  @Environment(DirectMessageInboxReader.self) private var inboxReader
  @Environment(CrossPostLogReader.self) private var crossPostLogReader
  @Environment(WindowState.self) private var windowState
  @Environment(\.attachmentMetadataResolver) private var injectedResolver

  // MARK: - G.8 grouped expand state

  /// Set of group IDs currently expanded in the feed. A group ID is:
  /// "grouped-<source.rawValue>-<senderPubkeyHex>-<spanStartMs>"
  @State private var expandedGroups: Set<String> = []

  // MARK: - G.9 Attachment metadata cache

  /// Keyed by `DirectMessageAttachment.externalRef`. Populated lazily via
  /// `.task(id: externalRef)` on each DM card. Graceful: card renders
  /// without attachment metadata embed but attachment label is still shown.
  @State private var attachmentMetadataCache: [String: AttachmentMetadata] = [:]

  /// @State fallback when the EnvironmentKey returns nil (unit-test
  /// snapshots or DB open failures).
  @State private var attachmentMetadataResolver: AttachmentMetadataResolver? = nil

  // MARK: - G.6 / H.6 transient scroll-to highlight

  /// Message id that is currently being highlighted as the deep-link target.
  /// Cleared via a Task.sleep timer ~2s after scroll-to fires.
  @State private var highlightedMessageID: String? = nil

  var body: some View {
    // G.5 — Filter chips (All / Messages / Open Tasks / Decisions / Blockers / More…)
    FeedFilterChipsBindable(store: feedFilterStore)
    // G.6-G.11 — Feed body: LazyVStack + card dispatch + empty states + pagination
    feedBody(workspaceID: active.id, members: members)
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
        // APNs deep-link can jump to the matched message cell.
        ScrollViewReader { proxy in
          ScrollView {
            // Team UI polish — day sections (Today / Yesterday / "May 20") +
            // per-section DM run flags. Flags are computed per section so a
            // message run never visually crosses a date separator.
            let sections = TeamFeedPresentation.daySections(
              items: items, now: Date(), calendar: .current)
            LazyVStack(spacing: LeafSpace.sm) {
              ForEach(sections) { section in
                let flags = TeamFeedPresentation.dmRenderFlags(items: section.items)
                LeafDateSeparator(label: section.label)
                ForEach(section.items) { item in
                  cardView(for: item, members: members, flags: flags)
                    .id(item.id)
                }
              }
              if hasMore {
                paginationSentinel(workspaceID: workspaceID)
              }
            }
            .padding(.bottom, LeafSpace.md)
          }
          // H.6 — observe deep-link target and scroll/highlight.
          // `initial: true`: the hub can mount this tab AFTER the deep-link
          // value was set (tab switch / fresh navigation).
          .onChange(of: windowState.pendingMessageID, initial: true) { _, newID in
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
          .onChange(of: windowState.focusReplyField, initial: true) { _, newValue in
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
  private func cardView(
    for item: FeedItem,
    members: [TeamMember],
    flags: [String: DMRenderFlags]
  ) -> some View {
    switch item {
    case .directMessage(let row):
      directMessageCard(row: row, members: members, flags: flags)
    case .teamEvent(let event):
      teamEventRow(event: event, members: members)
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
  private func directMessageCard(
    row: DirectMessageMirrorRow,
    members: [TeamMember],
    flags: [String: DMRenderFlags]
  ) -> some View {
    let isOutbound = row.senderPubkeyHex == selfPubkeyHex()
    let direction: MessageDirectionUI = isOutbound ? .outbound : .inbound
    // S7 Stage 6 fix C-I4 — read CrossPostLogReader for the badges. The
    // reader is populated by (a) Realtime POSTGRES_CHANGES push via
    // LeafRealtimeService → absorbRealtimePush, or (b) explicit
    // loadForMessages batch fetch (kicked from TeamView's feed-loaded
    // task). Empty array when the message has no cross-posts (most DMs).
    let crossPosts = crossPostLogReader.crossPosts(for: row.messageID)
    let cachedMeta = row.attachment.flatMap { attachmentMetadataCache[$0.externalRef] }
    let actions = computeActions(for: row, isOutbound: isOutbound)
    // Run flags: missing entry degrades to a standalone message (header on,
    // receipt off) — never silently hides information.
    let f = flags[row.messageID] ?? DMRenderFlags(showsHeader: true, showsReceipt: false)

    LeafMessageCard(
      row: row,
      direction: direction,
      showsHeader: f.showsHeader,
      showsReceipt: f.showsReceipt,
      recipientDisplayName: isOutbound
        ? TeamMemberNameResolver.displayName(
          pubkeyHex: row.recipientPubkeyHex, members: members)
        : nil,
      senderDisplayName: TeamMemberNameResolver.displayName(
        pubkeyHex: row.senderPubkeyHex, members: members,
        embeddedDisplayName: row.senderDisplayName),
      timestampStyle: TeamFeedPresentation.timestampStyle(
        forMs: row.serverCreatedAtMs, now: Date(), calendar: .current),
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
      // Until then this dismisses any open send sheet (nil recipient) —
      // semantics preserved from the pre-extraction TeamView.
      onSendDM(nil)
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
  private func teamEventRow(event: RenderedTeamEvent, members: [TeamMember]) -> some View {
    LeafFeedRow(
      event: event,
      senderDisplayName: TeamMemberNameResolver.displayName(
        pubkeyHex: event.row.senderPubkeyHex, members: members),
      attachmentMetadata: nil,
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
      onCTA: { onInvite() }
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
      onCTA: { onSendDM(nil) }  // Phase H: open recipient-picker
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
