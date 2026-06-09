//
//  LeafApp.swift
//  Leaf
//

import CryptoKit
import LeafCore
import SwiftUI
import UserNotifications
import os

#if LEAF_PROD
  import LeafCorePrivate
#endif

private let leafAppLogger = Logger(subsystem: "tech.gundem.leaf", category: "app")

@main
struct LeafApp: App {
  @NSApplicationDelegateAdaptor(LeafAppDelegate.self) private var appDelegate
  @State private var launchAgent: LaunchAgentService
  @State private var watchedFolders = WatchedFoldersService()
  @State private var linearOAuth = LinearOAuthService()
  @State private var githubOAuth = GitHubOAuthService()
  /// Phase Track-3 D2 — Task 21. Single shared `GitHubScopesReader` for Home /
  /// Connections / Sidebar forward-trust bindings (Tasks 18–20). Backed by an
  /// app-side `GitHubScopesService` reading the same `integrations.scope` row
  /// that `GitHubOAuthService` writes; Agent has its own service instance
  /// (Task 13) — no shared state needed since both read the same DB row.
  /// DB open mirrors `GitHubOAuthService.ensureDatabase()` shape (defaultURL +
  /// ProdConfigs + FileKeyStore encryption). On failure (e.g. FileKeyStore
  /// race at first launch) we pass `nil` — reader degrades to `.notConfigured`.
  @State private var githubScopes = GitHubScopesReader(
    service: LeafApp.makeGitHubScopesService()
  )
  @State private var slackOAuth = SlackOAuthService()
  /// Phase Track-3 D3 — Task 18. Shared `SlackScopesReader` mirroring the
  /// GitHub D2 forward-trust pattern (Home re-auth banner, Connections
  /// "Slack Scopes" section, Sidebar attention dot). Backed by an app-side
  /// `SlackScopesService` reading the same `integrations.scope` row the
  /// Agent's collector reads — both observe the same DB row, no shared
  /// state needed. `nil` on DB open failure → reader degrades to
  /// `.notConfigured`.
  @State private var slackScopes = SlackScopesReader(
    service: LeafApp.makeSlackScopesService()
  )
  @State private var permissions = PermissionsService()
  @State private var updater: UpdaterController
  @State private var lastSeenCursor = LastSeenCursor()
  @State private var diagnostics = DebugDiagnosticsService()
  @State private var routeCoordinator = RouteCoordinator()
  @State private var reader = InsightsReader()
  // Track 5 S2 Task 12 — `OrgReader` deleted. `WorkspaceReader` +
  // `ActiveWorkspaceStore` — sole substrate for workspace surface.
  @State private var activeWorkspaceStore: ActiveWorkspaceStore
  @State private var workspaceReader: WorkspaceReader
  /// Track 5 / S3 — Leaf's first network primitive. Constructed once at LeafApp.init
  /// time and injected into all invite readers + future S4+ readers.
  @State private var supabaseClient: SupabaseClient
  @State private var inviteOutboxReader: InviteOutboxReader
  @State private var inviteAcceptReader: InviteAcceptReader
  /// M027 invite-redesign — admin's local mirror of own-workspace invite tokens.
  @State private var inviteTokensReader: InviteTokensReader
  /// M027 — admin queue + invitee waiting state machine.
  @State private var joinRequestsReader: JoinRequestsReader
  /// Track 5 / S4 — DM send + inbox + APNs registration readers.
  @State private var directMessageSendReader: DirectMessageSendReader
  @State private var directMessageInboxReader: DirectMessageInboxReader
  @State private var apnsRegistrationReader: APNsRegistrationReader
  /// Track AI Coworker P4 — in-app team-handoff "Draft with AI" reader (first
  /// in-app AI surface). Self-resolves DB + prod AI moats (CR-2 parity).
  @State private var handoffDraftReader = HandoffDraftReader()
  /// Track 5 / S5 — Share Controls per-source toggle reader.
  @State private var shareRulesReader: ShareRulesReader
  /// Track 5 / S5 — sender-side broadcast loop reader.
  @State private var teamEventBroadcastReader: TeamEventBroadcastReader
  /// Track 5 / S5 — recipient-side mirror loop + retention pruner reader.
  @State private var teamEventMirrorReader: TeamEventMirrorReader
  /// Track 5 / S6 — cross-post UI readers + assignee resolver.
  @State private var slackChannelsReader: SlackChannelsReader
  @State private var linearTeamsReader: LinearTeamsReader
  @State private var linearScopesReader: LinearScopesReader
  @State private var linearUsersResolver: LinearUsersResolver
  /// Track 5 / S7 H.1 — Team feed reader + filter store + cross-post log
  /// + attachment metadata resolver + Realtime service. Wired in init below.
  @State private var teamFeedReader: TeamFeedReader
  @State private var crossPostLogReader: CrossPostLogReader
  @State private var attachmentMetadataResolver: AttachmentMetadataResolver?
  @State private var feedFilterStore: FeedFilterStore
  @State private var realtimeService: LeafRealtimeService
  @State private var memberRemovalReader = MemberRemovalReader()  // Phase 5.3.E
  @State private var pendingInvitesReader = PendingInvitesReader()  // Phase 5.5.C
  @State private var inviteURLHandler = InviteURLHandler()  // Phase 5.5.B
  /// Track 5 / S8 / T3 — local @Observable wrapper around TierGate static
  /// read. UI surfaces consume `@Environment(TierGateReader.self)` for the
  /// `canCreateWorkspace` / `canSendDM` / `canAcceptInvite` properties (T4
  /// wires per-callsite UpgradeModal sheets when these return false). The
  /// reader observes `UserDefaults.didChangeNotification` so `defaults
  /// write tech.gundem.leaf tier free` from Terminal flips UI live during
  /// QA — no app relaunch required.
  @State private var tierGateReader = TierGateReader()
  /// Track 5 / S8 / T9 — @Observable wrapper around NotificationPrefsStore
  /// (M026). Bound by NotificationsSettingsSection (4 sub-groups × 11
  /// prefs). Opens its own writer DB handle lazily on first refresh;
  /// best-effort server mirror via SupabaseClient for apns_push prefs hint.
  @State private var notificationPrefsReader: NotificationPrefsReader
  /// Track 5 / S8 T6 — daily-tick retry queue for APNs `dm.markDone`
  /// actions whose optimistic local UPDATE succeeded but server PATCH
  /// failed. nil when Database open fails at LeafApp.init (graceful: tick
  /// scheduler skips). Driven from `RootView.task(id:)` alongside the
  /// existing TeamEventMirrorRetentionPruner pruner tick.
  @State private var pendingMarkDoneRetryService: PendingMarkDoneRetryService?
  /// Track 5 / S8 / T8 — cache cascade DELETE + 30d auto-pruner. nil when
  /// Database open fails at init (graceful: hardDelete surfaces an error;
  /// daily tick is a no-op). Shared by WorkspaceReader.hardDelete (manual
  /// wipe) and RootView's daily-tick scheduler (auto-prune past 30d).
  @State private var workspaceCascadeDeleter: WorkspaceCascadeDeleter?
  @State private var windowState = WindowState()
  // Ph C migration-guard (D-C4 / R7) — non-nil when the on-disk DB carries
  // migrations a newer Leaf build wrote. Set ONCE in init() (single chokepoint,
  // before the ~25 scattered openForWrite callers); when set, the scene shows
  // DatabaseRecoveryView instead of the normal UI on every surface.
  @State private var schemaMismatch: DatabaseRecoveryInfo?
  @Environment(\.scenePhase) private var scenePhase

  init() {
    // Phase 3.4.5 — materialize db.key from the main app's Keychain group BEFORE `agent.register()`.
    // Helpers (LeafAgent/LeafMCP) live in other default Keychain access groups (without the shared
    // entitlement they can't see the main app's group), so if LeafAgent starts first,
    // it would generate its own random key and break the alpha.2 DB encrypted with the main app's K1.
    // The eager call here resolves the race deterministically.
    #if LEAF_PROD
      do {
        _ = try FileKeyStore.fetchOrCreate()
        FileKeyStore.cleanupLegacyKeychainBestEffort()
      } catch {
        // Don't crash — popover/Settings will surface the error via the InsightsReader state machine.
        leafAppLogger.error(
          "FileKeyStore.fetchOrCreate failed at init: \(String(describing: error), privacy: .public)"
        )
      }
    #endif

    // Register Derived Insights provider once per app launch. A direct
    // import + register is possible here because the app target is guaranteed
    // to receive the LEAF_PROD flag from xcconfig (unlike SPM
    // dependencies, where the flag isn't propagated).
    #if LEAF_PROD
      DerivedInsightsFactory.register { LeafCorePrivate.ProdInsights(database: $0) }
      // Track-10 T2 — subprocess-backed git delta reader for RESUME hero card.
      // Non-LEAF_PROD builds fall through to StubGitDeltaReader (returns nil).
      GitDeltaReaderFactory.register { LeafCorePrivate.ProdGitDeltaReader() }
      // Track-10 T1 C5 — moat-resident preset list ("common dev team
      // defaults") used by the onboarding `.shareControls` step. Public
      // builds fall through to `EmptyOnboardingShareTemplateProvider`,
      // which renders a "configure later in Settings" fallback panel.
      OnboardingShareTemplateFactory.register(LeafCorePrivate.ProdOnboardingShareTemplate())
    #endif

    // D13 (Phase 3.1) — explicit _state = State(initialValue:) pattern for
    // ordered initialization of @State properties (needed for the post-init register
    // call below). LaunchAgentService init synchronously reads SMAppService.status
    // → deterministic inline construction is required.
    // Ph C migration-guard (D-C4 / R7) — single pre-flight BEFORE the ~25
    // scattered openForWrite callers below. If the DB was written by a newer
    // Leaf build, every opener would throw/degrade-to-nil (and the TeamFeed
    // fallback would hit fatalError); instead we detect it once here, drive the
    // recovery UI from `schemaMismatch`, and keep init() crash-free.
    let schemaMismatchLocal = LeafApp.detectSchemaMismatch()
    _schemaMismatch = State(initialValue: schemaMismatchLocal)

    let agent = LaunchAgentService()
    _launchAgent = State(initialValue: agent)
    _updater = State(initialValue: UpdaterController())

    // Track 5 S2 Task 10 — explicit init pair: ActiveWorkspaceStore owns
    // the active-workspace UD key, WorkspaceReader subscribes to it. Both are
    // @MainActor — App.init is implicitly @MainActor, so the constructors are OK.
    //
    // Track 5 / S8 / T8 — WorkspaceCascadeDeleter share the same shared
    // SQLCipher DB handle as the Team feed substrate. We open the handle
    // first (was opened mid-init before T8), then construct the deleter,
    // then construct WorkspaceReader with the deleter so the hardDelete
    // path is wired from the moment any UI body renders. DB open failure
    // is graceful — the deleter is nil and `WorkspaceReader.hardDelete`
    // surfaces a user-facing error.
    let active = ActiveWorkspaceStore()
    _activeWorkspaceStore = State(initialValue: active)

    let sharedTeamFeedDB = LeafApp.makeDatabaseForTeamFeed()
    let cascadeDeleterLocal: WorkspaceCascadeDeleter? = sharedTeamFeedDB.map {
      WorkspaceCascadeDeleter(database: $0)
    }
    _workspaceCascadeDeleter = State(initialValue: cascadeDeleterLocal)

    // Track 5 / S3 — SupabaseClient is the first Mac client primitive talking to Supabase.
    // baseURL + anonKey read from Info.plist (xcconfig substitution).
    // Track 5 / S4 — adds SupabaseSessionStore for refresh_token persistence (closes I3).
    // M027 follow-up — construct Supabase BEFORE WorkspaceReader so the
    // reader can POST the workspaces row server-side on createWorkspace
    // (required for is_workspace_admin RLS helper).
    let supabaseSessionStore = SupabaseSessionStore(at: TeamKeystore.defaultRoot())
    let supabase = SupabaseClient(
      baseURL: SupabaseConfig.baseURL(from: Bundle.main),
      anonKey: SupabaseConfig.anonKey(from: Bundle.main),
      identity: { try IdentityService.ensureLocalIdentity(at: TeamKeystore.defaultRoot()) },
      sessionStore: supabaseSessionStore
    )
    _supabaseClient = State(initialValue: supabase)

    _workspaceReader = State(
      initialValue: WorkspaceReader(
        activeStore: active,
        supabase: supabase,
        cascadeDeleter: cascadeDeleterLocal
      ))
    _inviteOutboxReader = State(initialValue: InviteOutboxReader(supabase: supabase))
    _inviteAcceptReader = State(initialValue: InviteAcceptReader(supabase: supabase))
    _inviteTokensReader = State(
      initialValue: InviteTokensReader(
        supabase: supabase,
        workspaceReader: _workspaceReader.wrappedValue,
        activeWorkspaceStore: active
      ))
    _joinRequestsReader = State(
      initialValue: JoinRequestsReader(
        supabase: supabase,
        activeWorkspaceStore: active
      ))

    // Track 5 / S4 — direct-messages substrate readers.
    let sendReader = DirectMessageSendReader(supabase: supabase, activeWorkspaceStore: active)
    let inboxReader = DirectMessageInboxReader(supabase: supabase, activeWorkspaceStore: active)
    let apnsReader = APNsRegistrationReader(supabase: supabase)
    _directMessageSendReader = State(initialValue: sendReader)
    _directMessageInboxReader = State(initialValue: inboxReader)
    _apnsRegistrationReader = State(initialValue: apnsReader)

    // Track 5 / S5 — Share Controls reader. Reads + writes share_rules
    // table (defaults via ShareRuleDefaults when row absent).
    _shareRulesReader = State(initialValue: ShareRulesReader(activeStore: active))

    // Track 5 / S8 / T9 — Notification prefs reader. Reads + writes
    // notification_prefs (M026); best-effort server mirror via Supabase
    // for apns_push to skip pushes for disabled kinds.
    let notifPrefs = NotificationPrefsReader(supabaseClient: supabase)
    // Load saved per-kind prefs at launch so a kind the user disabled in a prior
    // session is honored before Settings is ever opened (refresh fails open to
    // defaults — handoff/task/ping ON — if the DB is unreachable).
    notifPrefs.refresh()
    _notificationPrefsReader = State(initialValue: notifPrefs)

    // Incoming-DM local notifications: when the inbox reader lands a new inbound
    // message (realtime or polling), build a notification plan from the master
    // toggle + per-kind prefs + content style, then schedule it. Dedup +
    // first-poll-batch suppression are handled inside the reader (notifTracker).
    let localMessageNotifier = LocalMessageNotifier()
    inboxReader.onIncomingInbound = { [notifPrefs] row in
      let masterEnabled = NotificationLocalPrefs.masterEnabled
      guard let kind = NotificationKind(rawValue: row.kind.rawValue) else { return }
      guard
        let plan = IncomingMessageNotificationDecider.decide(
          messageID: row.messageID,
          workspaceID: row.workspaceID,
          kind: row.kind,
          direction: row.direction,
          senderDisplayName: row.senderDisplayName,
          body: row.body,
          readAtMs: row.readAtMs,
          masterEnabled: masterEnabled,
          kindEnabled: notifPrefs.isEnabled(kind),
          soundEnabled: notifPrefs.isEnabled(.sound),
          bodyStyle: .bodyPreview,
          masterCanSilenceHandoff: false)
      else { return }
      localMessageNotifier.schedule(plan)
    }

    // Track 5 / S5 — broadcast + mirror readers + 30s tick scheduling
    // (driven by OrganizationView .task per S4 DM inbox precedent).
    _teamEventBroadcastReader = State(initialValue: TeamEventBroadcastReader(supabase: supabase))
    _teamEventMirrorReader = State(initialValue: TeamEventMirrorReader(supabase: supabase))

    // Track 5 / S6 T13 — cross-post composition wiring.
    // Track 5 / S8 carry-over (M20) — Slack channel picker production wiring.
    // ProdSlackChannelsProvider lives in the LeafCorePrivate moat (gitignored);
    // token resolution closure captures `sharedTeamFeedDB` opened above
    // for the WorkspaceCascadeDeleter and reads the OAuth access_token
    // from the IntegrationRecord on-demand per call — rotation pushed by
    // SlackTokenRefresher is picked up without re-construction.
    // Non-LEAF_PROD builds fall back to the empty-list Stub.
    #if LEAF_PROD
      let slackTokenProvider: @Sendable () async throws -> String = { [sharedTeamFeedDB] in
        guard let db = sharedTeamFeedDB else {
          throw NSError(
            domain: "tech.gundem.leaf.token", code: 1,
            userInfo: [
              NSLocalizedDescriptionKey: "Database unavailable"
            ])
        }
        guard let record = try db.readIntegration(provider: .slack) else {
          throw NSError(
            domain: "tech.gundem.leaf.token", code: 2,
            userInfo: [
              NSLocalizedDescriptionKey: "Slack not connected"
            ])
        }
        return record.accessToken
      }
      _slackChannelsReader = State(
        initialValue: SlackChannelsReader(
          provider: ProdSlackChannelsProvider(tokenProvider: slackTokenProvider)
        ))
    #else
      _slackChannelsReader = State(
        initialValue: SlackChannelsReader(provider: StubSlackChannelsProvider()))
    #endif

    // Track 5 / S8 carry-over (M20) — Linear team picker production wiring.
    // ProdLinearTeamsProvider lives in the LeafCorePrivate moat (gitignored);
    // same token-provider pattern as ProdSlackChannelsProvider above —
    // captures `sharedTeamFeedDB` and reads `IntegrationRecord(.linear)`
    // accessToken on-demand. Stub fallback for non-LEAF_PROD builds.
    #if LEAF_PROD
      let linearTokenProvider: @Sendable () async throws -> String = { [sharedTeamFeedDB] in
        guard let db = sharedTeamFeedDB else {
          throw NSError(
            domain: "tech.gundem.leaf.token", code: 1,
            userInfo: [
              NSLocalizedDescriptionKey: "Database unavailable"
            ])
        }
        guard let record = try db.readIntegration(provider: .linear) else {
          throw NSError(
            domain: "tech.gundem.leaf.token", code: 2,
            userInfo: [
              NSLocalizedDescriptionKey: "Linear not connected"
            ])
        }
        return record.accessToken
      }
      _linearTeamsReader = State(
        initialValue: LinearTeamsReader(
          provider: ProdLinearTeamsProvider(tokenProvider: linearTokenProvider)
        ))
    #else
      _linearTeamsReader = State(
        initialValue: LinearTeamsReader(provider: StubLinearTeamsProvider()))
    #endif

    // LinearScopesReader wraps LinearScopesService (DB-backed) + adapter
    // bridging the Sendable `LinearOAuthReauthorizing` protocol to the
    // app-target `LinearOAuthService.connect()` flow (which opens browser).
    // _linearOAuth.wrappedValue used here because Swift can't prove `self`
    // is initialized for `self.linearOAuth` access before all @State props
    // are set — the underlying storage IS initialized at declaration.
    let linearScopesService = LeafApp.makeLinearScopesService()
    let linearReauth = LinearOAuthReauthorizeAdapter(service: _linearOAuth.wrappedValue)
    _linearScopesReader = State(
      initialValue: LinearScopesReader(
        service: linearScopesService ?? LinearScopesService(grantedOverride: []),
        reauthorizer: linearReauth
      ))

    // LinearUsersResolver — fuzzy assignee resolution (T9).
    // Track 5 / S8 carry-over (M20) — swap Stub for ProdLinearAccessibleUsersClient
    // under #if LEAF_PROD. The `linearTokenProvider` closure declared above
    // (inside the LinearTeams #if LEAF_PROD block) is reused here — both
    // call sites pull the same `IntegrationRecord(.linear).accessToken`.
    // The closure is in lexical scope across #if-LEAF_PROD lines because
    // Swift conditional compilation gates lines, not scopes. Stub fallback
    // preserved for non-LEAF_PROD builds.
    #if LEAF_PROD
      _linearUsersResolver = State(
        initialValue: LinearUsersResolver(
          provider: ProdLinearAccessibleUsersClient(tokenProvider: linearTokenProvider)
        ))
    #else
      _linearUsersResolver = State(
        initialValue: LinearUsersResolver(
          provider: StubLinearGraphQLProvider()
        ))
    #endif

    // Track 5 / S7 H.1 — Team feed substrate composition.
    //
    // Dependency order:
    //   1. Database open for AttachmentMetadataResolver actor (DB-backed,
    //      reads `events` table via json_extract for local resolution).
    //      Falls back to nil-resolver on DB open failure (graceful: TeamView
    //      already handles `nil` resolver — attachment cards render label-only).
    //   2. TeamFeedQueryService — depends on Database (shared with resolver
    //      where available; constructed via its own open if separate).
    //   3. TeamFeedReader — wraps QueryService + memberResolver closure that
    //      looks up TeamMember by pubkeyHex from the live WorkspaceReader.
    //   4. CrossPostLogReader — wraps SupabaseClient for cache fetches.
    //   5. FeedFilterStore — no deps; UserDefaults-backed.
    //   6. RealtimeWebSocketDriver — actor; URLSession.shared by default.
    //   7. LeafRealtimeService — wraps driver + supabase + active store +
    //      inbox/mirror readers + cross-post reader + decryption closures.
    // Track 5 / S8 / T8 — reuse `sharedTeamFeedDB` (opened above for the
    // WorkspaceCascadeDeleter init) instead of opening a second handle.
    // Single DB handle per app process — saves a file descriptor and keeps
    // the writer-mode pool count predictable for cross-process locks.
    let attachmentResolver: AttachmentMetadataResolver?
    let teamFeedQueryDB: LeafCore.Database?
    if let resolverDB = sharedTeamFeedDB {
      attachmentResolver = AttachmentMetadataResolver(
        database: resolverDB,
        collectorsRegistry: nil  // Phase H+1: wire GitHub/Linear/Slack collector providers
      )
      teamFeedQueryDB = resolverDB
    } else {
      attachmentResolver = nil
      teamFeedQueryDB = nil
    }
    _attachmentMetadataResolver = State(initialValue: attachmentResolver)

    // TeamFeedReader requires a QueryService. On DB open failure we still
    // need a constructable reader so .environment() injection doesn't crash;
    // we open a second DB handle as a best-effort (same default URL). If
    // that also fails the reader will surface .error on first loadInitial.
    let queryServiceDB = teamFeedQueryDB ?? LeafApp.makeDatabaseForTeamFeed()
    // memberResolver closure captures the local `let workspaceReader = ...`
    // ref (which is initialized above via the explicit _workspaceReader
    // pattern). We capture weakly to avoid retention through the closure.
    let workspaceReaderLocal = _workspaceReader.wrappedValue
    let memberResolver: (String) -> TeamMember? = { [weak workspaceReaderLocal] pubkeyHex in
      guard let reader = workspaceReaderLocal else { return nil }
      if case .loaded(_, _, let members) = reader.state {
        return members.first { $0.pubkeyHex == pubkeyHex }
      }
      return nil
    }
    if let qdb = queryServiceDB {
      let queryService = TeamFeedQueryService(database: qdb)
      _teamFeedReader = State(
        initialValue: TeamFeedReader(
          queryService: queryService,
          memberResolver: memberResolver
        ))
    } else {
      // Last-resort fallback — open a throw-away in-memory query service
      // is not supported by TeamFeedQueryService (it requires Database).
      // We surface the error path by opening a default URL once more and
      // letting failures bubble at first fetch time. If both opens above
      // failed we'd already be in a broken state; assert + force-init
      // via the default URL on a fresh DatabaseConfig so the type compiles.
      leafAppLogger.error("TeamFeedReader degraded: DB open failures in init")
      // We *must* hand TeamFeedReader something — synthesize a Database
      // by re-attempting the default open. If this still fails, crash
      // here is acceptable because the entire feed substrate cannot work.
      let fallbackDB = try? LeafCore.Database.openForWrite(
        at: DatabasePath.defaultURL(),
        config: DatabaseConfig.weakDefaults,
        encryption: nil
      )
      if let fdb = fallbackDB {
        let queryService = TeamFeedQueryService(database: fdb)
        _teamFeedReader = State(
          initialValue: TeamFeedReader(
            queryService: queryService,
            memberResolver: memberResolver
          ))
      } else if schemaMismatchLocal != nil,
        let tmp = try? LeafCore.Database.openForWrite(
          at: FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-recovery-\(UUID().uuidString).sqlite"),
          config: DatabaseConfig.weakDefaults,
          encryption: nil)
      {
        // Future-schema DB: the recovery UI takes over the window, but init must
        // still finish. Hand TeamFeedReader a throwaway temp DB (migrates fresh,
        // empty, never shown) rather than crashing on the line below.
        let queryService = TeamFeedQueryService(database: tmp)
        _teamFeedReader = State(
          initialValue: TeamFeedReader(
            queryService: queryService,
            memberResolver: memberResolver
          ))
      } else {
        // Genuine cold-start broken state (not schema-from-future) — fatalError
        // keeps the crash localized to init rather than a confusing null deref.
        fatalError("LeafApp init: cannot open SQLCipher database for TeamFeed")
      }
    }

    _crossPostLogReader = State(initialValue: CrossPostLogReader(supabase: supabase))
    _feedFilterStore = State(initialValue: FeedFilterStore(userDefaults: .standard))

    // Realtime substrate. Driver = actor with URLSession.shared by default.
    // P1 re-dispatch — Important-2 race fix. The JWT provider is wired at
    // init time so the driver has it available the moment any reconnect
    // attempt fires (eliminates the prior async install Task race where a
    // transport-level reconnect could race ahead of `setJWTProvider`).
    let realtimeDriver = RealtimeWebSocketDriver(
      jwtProvider: { [supabase] in
        try? await supabase.ensureFreshSession().accessToken
      }
    )
    let realtimeURL = LeafApp.realtimeURL(forSupabase: supabase)

    // Track 5 / S8 / T0 — Phase H Realtime decryption wiring.
    //
    // The closures forward an `EncryptedTeamEventInput` /
    // `EncryptedDirectMessageInput` (narrow shape with NO senderPubkeyHex /
    // kind / replyTo — compile-time fence, see EncryptedRow.swift) to the
    // reader's `decryptOnly(_:)` method, which delegates to the wrapped
    // service. Service performs keystore lookup + AES-GCM decode via the
    // injected codec (Prod codec under LEAF_PROD; Unimplemented stub
    // otherwise — non-LEAF_PROD builds will silently no-op on Realtime).
    //
    // The C2/C3 plaintext-trust gates run INSIDE
    // `LeafRealtimeService.handleTeamEventInsert` /
    // `handleDirectMessageInsert` AFTER the decryptor returns —
    // structural fence makes it a compile-time impossibility for the
    // closure to bypass them.
    //
    // 30s polling fallback (OrganizationView .task tick) remains as
    // safety net for the cold-start case where Realtime hasn't connected
    // yet, or LEAF_PROD-off dev builds.
    let mirrorReader = _teamEventMirrorReader.wrappedValue
    let teamEventDecryptor: LeafRealtimeService.TeamEventDecryptor = { [weak mirrorReader] input in
      guard let mirrorReader else {
        throw LeafError.notImplemented
      }
      return try await mirrorReader.decryptOnly(input)
    }
    let dmInboxReader = inboxReader
    let directMessageDecryptor: LeafRealtimeService.DirectMessageDecryptor = {
      [weak dmInboxReader] input in
      guard let dmInboxReader else {
        throw LeafError.notImplemented
      }
      return try await dmInboxReader.decryptOnly(input)
    }

    let crossPostLog = _crossPostLogReader.wrappedValue
    let realtime = LeafRealtimeService(
      driver: realtimeDriver,
      supabase: supabase,
      activeWorkspaceStore: active,
      directMessageInboxReader: inboxReader,
      teamEventMirrorReader: _teamEventMirrorReader.wrappedValue,
      crossPostLogReader: crossPostLog,
      realtimeURL: realtimeURL,
      teamEventDecryptor: teamEventDecryptor,
      directMessageDecryptor: directMessageDecryptor
    )
    _realtimeService = State(initialValue: realtime)

    // C1 fix — Track 5 / S4 Stage 6 review:
    // AppDelegate handles APNs callbacks and needs reader references. SwiftUI
    // doesn't propagate @Environment into AppDelegate callbacks; static weak
    // refs bridge that gap. Populated here before any APNs registration fires.
    LeafAppDelegate.directMessageInboxReader = inboxReader
    LeafAppDelegate.apnsRegistrationReader = apnsReader
    // Track 5 / S7 H.6 — APNs notification click → deep-link to TeamView +
    // scroll-to/highlight the message cell. Same static-ref bridge pattern.
    LeafAppDelegate.windowState = _windowState.wrappedValue
    LeafAppDelegate.activeWorkspaceStore = active
    // Track 5 / S8 T6 — APNs `dm.markDone` action handler needs the
    // SendReader reference (UI in-app [Mark Done] path delegates to
    // InboxReader.markDone; the AppDelegate keeps a separate ref purely
    // for symmetry with the static-bridge convention used by the other
    // AppDelegate consumers and for future Track 6 reply-send wiring).
    LeafAppDelegate.directMessageSendReader = sendReader
    // Settings dead-toggle remediation (WS2) — willPresent reads notification
    // prefs + latest focus state from the shared events DB (same SQLCipher file
    // the agent writes focus_mode_* events into).
    LeafAppDelegate.notificationDatabase = sharedTeamFeedDB

    // Track 5 / S8 T6 — construct PendingMarkDoneRetryService over the
    // shared Team feed DB handle (same SQLCipher events.sqlite file as the
    // rest of the app). On DB open failure (`teamFeedQueryDB == nil`) the
    // service stays nil — RootView's daily-tick scheduler honours nil
    // and skips silently.
    if let db = teamFeedQueryDB {
      let keystoreRoot = TeamKeystore.defaultRoot()
      let retryClient: PendingMarkDoneRetryService.MarkDoneClient = { [supabase] messageID in
        // Resolve self pubkey lazily inside the closure so a key
        // rotation between LeafApp.init and the retry tick still
        // hands the current value. Throws on identity read failure
        // — wrapped in actor.tick's catch; row stays pending for
        // the next tick.
        let priv = try IdentityService.ensureLocalIdentity(at: keystoreRoot)
        let pubkeyHex = priv.publicKey.rawRepresentation
          .map { String(format: "%02x", $0) }
          .joined()
        // Inline ISO8601 formatter — matches the format used by
        // SupabaseClient.markDone callsites (see DirectMessageService.markDone
        // + DirectMessageInboxReader.markDone). Avoids capturing a
        // Sendable dependency on the reader-owned helpers.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let nowISO = formatter.string(from: Date())
        try await supabase.markDone(
          messageID: messageID,
          doneAtISO: nowISO,
          doneByPubkeyHex: pubkeyHex
        )
      }
      _pendingMarkDoneRetryService = State(
        initialValue: PendingMarkDoneRetryService(
          mirror: db,
          markDone: retryClient
        ))
    }

    // D1 — idempotent register for post-update relaunch restoration.
    // Sparkle relaunches the app after a bundle replace + cold launch without the update flow:
    // if already enabled (status restored by launchd) — the register() "already
    // registered" filter in LaunchAgentService prevents a spurious red error.
    // Multi-process choreography: SMAppService.register triggers launchd to
    // SIGTERM the old agent (if a different binary path) and start the new agent — existing
    // SignalHandlers (Agent.swift:131) flush WAL gracefully. See the UpdaterController
    // doc-comment about the D14 deviation from master plan A2 D2.
    if !agent.isEnabled {
      agent.register()
    }
  }

  var body: some Scene {
    Window("Leaf", id: "main") {
      if let mismatch = schemaMismatch {
        DatabaseRecoveryView(info: mismatch)
      } else {
        RootView()
        .environment(launchAgent)
        .environment(watchedFolders)
        .environment(linearOAuth)
        .environment(githubOAuth)
        .environment(githubScopes)  // Phase Track-3 D2 — Task 21
        .environment(slackOAuth)
        .environment(slackScopes)  // Phase Track-3 D3 — Task 18
        .environment(permissions)
        .environment(updater)
        .environment(reader)
        .environment(lastSeenCursor)  // Track-10 T5
        .environment(diagnostics)  // dev-launch-reliability — Settings Diagnostics
        .environment(routeCoordinator)  // Track-10 — Home/ResumeHero routing
        .environment(workspaceReader)  // Track 5 S2 Task 10
        .environment(activeWorkspaceStore)  // Track 5 S2 Task 10
        // Track 5 / S3 — SupabaseClient is an actor (not @Observable), injected directly
        // into readers via constructor. UI surfaces consume readers, not the client directly.
        .environment(inviteOutboxReader)
        .environment(inviteAcceptReader)
        .environment(inviteTokensReader)  // M027 invite-redesign
        .environment(joinRequestsReader)  // M027 invite-redesign
        .environment(directMessageSendReader)  // Track 5 / S4
        .environment(handoffDraftReader)  // AI Coworker P4 — Draft with AI
        .environment(directMessageInboxReader)  // Track 5 / S4
        .environment(apnsRegistrationReader)  // Track 5 / S4
        .environment(shareRulesReader)  // Track 5 / S5
        .environment(teamEventBroadcastReader)  // Track 5 / S5
        .environment(teamEventMirrorReader)  // Track 5 / S5
        .environment(slackChannelsReader)  // Track 5 / S6
        .environment(linearTeamsReader)  // Track 5 / S6
        .environment(linearScopesReader)  // Track 5 / S6
        // LinearUsersResolver is an actor (not @Observable); plumbed via
        // explicit closure into Send sheet from OrganizationView call site.
        .environment(\.linearUsersResolver, linearUsersResolver)
        .environment(teamFeedReader)  // Track 5 / S7 H.3
        .environment(crossPostLogReader)  // Track 5 / S7 H.3
        .environment(feedFilterStore)  // Track 5 / S7 H.3
        .environment(realtimeService)  // Track 5 / S7 H.3
        // AttachmentMetadataResolver is an actor (not @Observable);
        // custom EnvironmentKey threads optional resolver to TeamView.
        .environment(\.attachmentMetadataResolver, attachmentMetadataResolver)
        .environment(memberRemovalReader)  // Phase 5.3.E
        .environment(pendingInvitesReader)  // Phase 5.5.C
        .environment(inviteURLHandler)  // Phase 5.5.B
        .environment(tierGateReader)  // Track 5 / S8 / T3
        .environment(notificationPrefsReader)  // Track 5 / S8 / T9
        // T4 — UpgradeModal callsites (Sheet/TeamView Free branch/Sidebar
        // Free state) invoke `submitToWaitlist(email:)` via this env closure.
        // SupabaseClient is an actor (not @Observable), so we wrap it in a
        // @Sendable closure here at composition-time; views stay SwiftUI-pure.
        .environment(
          \.submitToWaitlist,
          { [supabaseClient] email in
            await supabaseClient.submitToWaitlist(email: email)
          }
        )
        // Track 5 / S8 T6 — PendingMarkDoneRetryService threaded as
        // optional Sendable actor via custom EnvironmentKey (actors
        // can't conform to Observation tracking). RootView's
        // .task(id:) daily-tick scheduler reads + invokes .tickIfDueDaily.
        .environment(\.pendingMarkDoneRetryService, pendingMarkDoneRetryService)
        // Track 5 / S8 / T8 — WorkspaceCascadeDeleter threaded the same
        // way; RootView's daily-tick scheduler invokes
        // `pruneExpiredLeftWorkspaces()` to wipe workspaces past the
        // 30-day retention threshold (left_at_ms OR deleted_at_ms).
        .environment(\.workspaceCascadeDeleter, workspaceCascadeDeleter)
        .environment(windowState)
        .onAppear {
          inviteURLHandler.wire(
            acceptReader: inviteAcceptReader,
            outboxReader: inviteOutboxReader)
          // M027 invite-redesign — late-bind reader + WindowState refs.
          inviteURLHandler.wireM027(
            joinRequestsReader: joinRequestsReader,
            windowState: windowState
          )
          // Admin roster refreshes immediately after an approve (Bug B inserts
          // the invitee into the local team_members). Both readers are
          // app-lifetime; weak capture for symmetry, no retain cycle.
          let wsReader = workspaceReader
          joinRequestsReader.wireRosterRefresh { [weak wsReader] in
            wsReader?.refresh()
          }
          // Resume any invite approved while the invitee wasn't on the open
          // waiting card (dismissed / app quit before approve) — otherwise the
          // approved+sealed request is stranded forever. Runs AFTER
          // wireRosterRefresh so materialisation's sidebar refresh hook is set.
          Task { await joinRequestsReader.resumePendingMaterialisations() }
        }
                .task {
                    // Track-10 T6 (Phase IV.B) — inject ActiveWorkspaceStore
                    // FIRST (field-only, no refresh) so the cursor configure's
                    // launch refresh already sees it for the solo-vs-team
                    // memberCount gate.
                    reader.configure(activeWorkspaceStore: activeWorkspaceStore)
                    // Track-10 T5 — two-phase init for LastSeenCursor injection
                    // (refresh()-triggers first SINCE feed population).
                    reader.configure(lastSeenCursor: lastSeenCursor)
                }
        .onOpenURL { url in
          inviteURLHandler.handle(url)
        }
        .onChange(of: scenePhase) { _, newPhase in
          // Phase 5.5.B — invitee comes back to Leaf after admin sent invite link;
          // probe the clipboard for auto-fetch without a manual paste step. Deep-link path
          // (`.onOpenURL`) covers click-to-open; this covers Cmd-Tab-from-chat-app.
          guard newPhase == .active else { return }
          if case .inviteURL(let url) = inviteURLHandler.probeClipboard() {
            inviteAcceptReader.fetch(inviteURL: url)
          }
        }
      }
    }
    .defaultSize(width: 1100, height: 720)
    .windowResizability(.contentMinSize)
    .commands {
      CommandGroup(replacing: .appSettings) {
        OpenSettingsCommand(windowState: windowState)
      }
      #if DEBUG
        CommandGroup(after: .windowArrangement) {
          OpenTokensPreviewCommand()
        }
      #endif
    }

    #if DEBUG
      Window("Tokens Preview", id: "tokens-preview") {
        TokensPreviewScreen()
      }
      .defaultSize(width: 1100, height: 800)
    #endif

    MenuBarExtra("Leaf", image: LeafIcons.brand.leaf) {
      if let mismatch = schemaMismatch {
        DatabaseRecoveryView(info: mismatch)
          .frame(width: 360)
      } else {
        MenuBarContent()
        .environment(launchAgent)
        .environment(watchedFolders)
        .environment(permissions)
        .environment(updater)
        .environment(reader)
        .environment(lastSeenCursor)  // Track-10 T5
        .environment(diagnostics)  // dev-launch-reliability — Settings Diagnostics
        .environment(routeCoordinator)  // Track-10 — Home/ResumeHero routing
        .environment(workspaceReader)  // Track 5 S2 Task 10
        .environment(activeWorkspaceStore)  // Track 5 S2 Task 10
        .environment(inviteAcceptReader)
        .environment(inviteURLHandler)  // Phase 5.5.B
        .environment(windowState)
      }
    }
    .menuBarExtraStyle(.window)
  }

  // MARK: - GitHub scopes reader DB bootstrap (Task 21)

  /// Mirrors `GitHubOAuthService.ensureDatabase()` open-shape (default URL +
  /// ProdConfigs + FileKeyStore-backed encryption). Called once at @State
  /// initialization for the shared `GitHubScopesReader`. Returns `nil` on
  /// failure so the reader stays in `.notConfigured` rather than crashing
  /// the app cold-start (e.g., FileKeyStore race / disk error).
  private static func makeGitHubScopesService() -> GitHubScopesService? {
    let url = DatabasePath.defaultURL()
    #if LEAF_PROD
      let config = ProdConfigs.database
      let encryption: EncryptionOptions? = EncryptionOptions(
        keyProvider: .callback { @Sendable in
          try FileKeyStore.fetchOrCreate()
        },
        preKeyPragmas: ProdConfigs.sqlcipherPragmasPreKey,
        postKeyPragmas: ProdConfigs.sqlcipherPragmasPostKey
      )
    #else
      let config = DatabaseConfig.weakDefaults
      let encryption: EncryptionOptions? = nil
    #endif
    do {
      let db = try LeafCore.Database.openForWrite(at: url, config: config, encryption: encryption)
      return GitHubScopesService(database: db)
    } catch {
      leafAppLogger.error(
        "makeGitHubScopesService failed: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  // MARK: - Linear scopes reader DB bootstrap (Track 5 / S6 T13)

  /// Same DB-open shape as `makeGitHubScopesService` — `LinearScopesService`
  /// reads its `provider = linear` row from the same encrypted SQLCipher file.
  /// Returns `nil` on failure → composition root falls back to empty-grant
  /// LinearScopesService (UI shows scope-missing banner permanently).
  private static func makeLinearScopesService() -> LinearScopesService? {
    let url = DatabasePath.defaultURL()
    #if LEAF_PROD
      let config = ProdConfigs.database
      let encryption: EncryptionOptions? = EncryptionOptions(
        keyProvider: .callback { @Sendable in
          try FileKeyStore.fetchOrCreate()
        },
        preKeyPragmas: ProdConfigs.sqlcipherPragmasPreKey,
        postKeyPragmas: ProdConfigs.sqlcipherPragmasPostKey
      )
    #else
      let config = DatabaseConfig.weakDefaults
      let encryption: EncryptionOptions? = nil
    #endif
    do {
      let db = try LeafCore.Database.openForWrite(at: url, config: config, encryption: encryption)
      return LinearScopesService(database: db)
    } catch {
      leafAppLogger.error(
        "makeLinearScopesService failed: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  // MARK: - Team feed DB bootstrap + Realtime URL (Track 5 / S7 H.1)

  /// Same DB-open shape as `makeGitHubScopesService` — used by
  /// `AttachmentMetadataResolver` (reads events table via json_extract) and
  /// `TeamFeedQueryService` (reads messages_mirror + team_events_mirror via
  /// UNION). Returns `nil` on failure so callers can fall back gracefully.
  /// Ph C migration-guard (D-C4 / R7) — one-shot probe at init: if the on-disk
  /// DB carries migrations this binary does not know (written by a newer Leaf
  /// build), return recovery info for the alert. `nil` on a fresh device (no
  /// file), a current/older schema, or any non-schema open error (those keep
  /// flowing through the existing InsightsReader error state). Read-only probe,
  /// closed immediately.
  private static func detectSchemaMismatch() -> DatabaseRecoveryInfo? {
    let url = DatabasePath.defaultURL()
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    #if LEAF_PROD
      let config = ProdConfigs.database
      let encryption: EncryptionOptions? = EncryptionOptions(
        keyProvider: .callback { @Sendable in
          try FileKeyStore.fetchOrCreate()
        },
        preKeyPragmas: ProdConfigs.sqlcipherPragmasPreKey,
        postKeyPragmas: ProdConfigs.sqlcipherPragmasPostKey
      )
    #else
      let config = DatabaseConfig.weakDefaults
      let encryption: EncryptionOptions? = nil
    #endif
    do {
      _ = try LeafCore.Database.openForRead(at: url, config: config, encryption: encryption)
      return nil
    } catch let LeafError.databaseSchemaFromFuture(unknown) {
      leafAppLogger.error(
        "DB schema from future — unknown migrations: \(unknown.joined(separator: ","), privacy: .public)")
      return DatabaseRecoveryInfo(unknownMigrations: unknown, dbPath: url.path)
    } catch {
      // Non-schema open failure (corruption / key) — leave to InsightsReader.
      return nil
    }
  }

  private static func makeDatabaseForTeamFeed() -> LeafCore.Database? {
    let url = DatabasePath.defaultURL()
    #if LEAF_PROD
      let config = ProdConfigs.database
      let encryption: EncryptionOptions? = EncryptionOptions(
        keyProvider: .callback { @Sendable in
          try FileKeyStore.fetchOrCreate()
        },
        preKeyPragmas: ProdConfigs.sqlcipherPragmasPreKey,
        postKeyPragmas: ProdConfigs.sqlcipherPragmasPostKey
      )
    #else
      let config = DatabaseConfig.weakDefaults
      let encryption: EncryptionOptions? = nil
    #endif
    do {
      return try LeafCore.Database.openForWrite(at: url, config: config, encryption: encryption)
    } catch {
      leafAppLogger.error(
        "makeDatabaseForTeamFeed failed: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  /// Derive the Supabase Realtime WebSocket URL from the configured base URL.
  ///
  /// Format per Supabase Realtime convention:
  ///   `wss://<project>.supabase.co/realtime/v1/websocket?apikey=<anon>&vsn=1.0.0`
  ///
  /// SupabaseClient.baseURL is typically `https://<project>.supabase.co` (or
  /// `http://127.0.0.1:54321` for local dev). We swap scheme to `wss`/`ws` and
  /// append the path + query.
  nonisolated static func realtimeURL(forSupabase supabase: SupabaseClient) -> URL {
    let baseURL = supabase.baseURL
    let anonKey = supabase.anonKey
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
    // Map http→ws, https→wss; default to wss for unknown.
    switch components.scheme?.lowercased() {
    case "http": components.scheme = "ws"
    case "https": components.scheme = "wss"
    default: components.scheme = "wss"
    }
    components.path = "/realtime/v1/websocket"
    var qs = components.queryItems ?? []
    qs.append(URLQueryItem(name: "apikey", value: anonKey))
    qs.append(URLQueryItem(name: "vsn", value: "1.0.0"))
    components.queryItems = qs
    // Fallback if URLComponents fails — defensively never crash here.
    return components.url ?? baseURL
  }

  // MARK: - Slack scopes reader DB bootstrap (Task 18, mirrors GitHub above)

  /// Same DB-open shape as `makeGitHubScopesService()` — `SlackScopesService`
  /// reads its `provider = slack` row from the same encrypted SQLCipher file.
  /// Returns `nil` on failure so the reader stays in `.notConfigured`.
  private static func makeSlackScopesService() -> SlackScopesService? {
    let url = DatabasePath.defaultURL()
    #if LEAF_PROD
      let config = ProdConfigs.database
      let encryption: EncryptionOptions? = EncryptionOptions(
        keyProvider: .callback { @Sendable in
          try FileKeyStore.fetchOrCreate()
        },
        preKeyPragmas: ProdConfigs.sqlcipherPragmasPreKey,
        postKeyPragmas: ProdConfigs.sqlcipherPragmasPostKey
      )
    #else
      let config = DatabaseConfig.weakDefaults
      let encryption: EncryptionOptions? = nil
    #endif
    do {
      let db = try LeafCore.Database.openForWrite(at: url, config: config, encryption: encryption)
      return SlackScopesService(database: db)
    } catch {
      leafAppLogger.error(
        "makeSlackScopesService failed: \(String(describing: error), privacy: .public)")
      return nil
    }
  }
}

/// `applicationShouldHandleReopen` is needed so that a click on the Dock icon (after
/// the user has closed the window) reopens the main window. Without it, the SwiftUI
/// `Window` doesn't react to reopen — the menu-bar presence "swallows" the event.
///
/// Track 5 / S4 — Stage 6 review C1 fix: APNs callbacks added.
/// AppDelegate keeps weak refs to readers via MainActor-isolated static
/// accessors that LeafApp.init populates. SwiftUI doesn't propagate
/// `@Environment` into AppDelegate callbacks, so static handoff is the
/// pragmatic bridge.
final class LeafAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

  @MainActor static weak var apnsRegistrationReader: APNsRegistrationReader?
  @MainActor static weak var directMessageInboxReader: DirectMessageInboxReader?
  /// Track 5 / S7 H.6 — Deep-link targets for APNs notification click.
  /// Populated by LeafApp.init before any APNs delivery can fire.
  @MainActor static weak var windowState: WindowState?
  @MainActor static weak var activeWorkspaceStore: ActiveWorkspaceStore?
  /// Track 5 / S8 T6 — APNs `dm.markDone` action runs WITHOUT opening the
  /// app. We dispatch into `DirectMessageInboxReader.markDone(messageID:)`
  /// (the same reader that owns the in-app [Mark Done] button path) so the
  /// optimistic local UPDATE + retry-queue flow runs identically whether
  /// the user taps in-app or via banner action.
  @MainActor static weak var directMessageSendReader: DirectMessageSendReader?

  /// Settings dead-toggle remediation (WS2) — strong handle to the local
  /// events DB so willPresent can read notification prefs + the latest focus
  /// state. Strong (not weak): a menubar app keeps this for its whole lifetime,
  /// and willPresent must never lose the pref store. Populated by LeafApp.init.
  @MainActor static var notificationDatabase: LeafCore.Database?
  /// Foreground-presentation timestamps for the coalesce window (WS2).
  @MainActor private static var recentPresentationsMs: [Int64] = []

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !flag {
      // Find the existing SwiftUI Window (id="main") by its identifier and bring it forward.
      for window in sender.windows where window.identifier?.rawValue.contains("main") == true {
        window.makeKeyAndOrderFront(nil)
        sender.activate(ignoringOtherApps: true)
        return false
      }
    }
    return true
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Track 5 / S4 — APNs registration. Requires aps-environment entitlement
    // (added separately for signed builds). In dev / unsigned builds, the
    // registration request silently no-ops on macOS.
    UNUserNotificationCenter.current().delegate = self

    // Track 5 / S8 / T5 — bind UNNotificationCategory set so delivered
    // pushes whose `aps.category = "leaf.dm.<kind>"` field matches an
    // entry here render the listed actions (Reply / Mark Done) in the
    // banner and Notification Center. Static config lives in
    // `LeafCore/Notifications/NotificationCategoryRegistry`; action
    // handlers wire in T6 via `userNotificationCenter(didReceive:)`.
    UNUserNotificationCenter.current().setNotificationCategories(
      Set(NotificationCategoryRegistry.all)
    )

    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .sound, .badge]
    ) { granted, _ in
      guard granted else { return }
      DispatchQueue.main.async {
        NSApplication.shared.registerForRemoteNotifications()
      }
    }
  }

  func application(
    _ application: NSApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let tokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
    let env: String
    #if DEBUG
      env = "development"
    #else
      env = "production"
    #endif
    Task { @MainActor in
      await Self.apnsRegistrationReader?.recordToken(tokenHex, environment: env)
    }
  }

  func application(
    _ application: NSApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    leafAppLogger.error("APNs register failed: \(String(describing: error), privacy: .public)")
  }

  func application(
    _ application: NSApplication,
    didReceiveRemoteNotification userInfo: [String: Any]
  ) {
    // Spec §10.3 payload: leaf_message_id + leaf_workspace_id.
    guard let messageID = userInfo["leaf_message_id"] as? String,
      let workspaceID = userInfo["leaf_workspace_id"] as? String
    else {
      return
    }
    Task { @MainActor in
      await Self.directMessageInboxReader?.tickOnce(
        workspaceID: workspaceID, forMessageID: messageID
      )
    }
  }

  // MARK: UNUserNotificationCenterDelegate

  /// Show banner / sound when notification arrives while app is foregrounded.
  /// Without this delegate method, macOS silently drops foreground notifications.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    return await MainActor.run { Self.foregroundPresentationOptions(nowMs: nowMs) }
  }

  /// Settings dead-toggle remediation (WS2) — decide foreground banner/sound/
  /// badge from the user's Behavior prefs (respectFocus / sound / coalesce) plus
  /// the latest focus state (read from the shared DB the agent writes). Applies
  /// only while Leaf is foreground — background delivery is server-governed.
  /// Fail-open to the full set if the pref store is unreachable.
  @MainActor
  static func foregroundPresentationOptions(nowMs: Int64) -> UNNotificationPresentationOptions {
    guard let db = notificationDatabase else { return [.banner, .sound, .badge] }
    let sound = (try? db.isNotificationPrefEnabled(.sound)) ?? true
    let respectFocus = (try? db.isNotificationPrefEnabled(.respectFocus)) ?? true
    let coalesce = (try? db.isNotificationPrefEnabled(.coalesce)) ?? true
    let inFocus = (try? db.latestFocusIsActive()) ?? false
    recentPresentationsMs = recentPresentationsMs.filter {
      nowMs - $0 < NotificationPresentationDecider.coalesceWindowMs
    }
    let decision = NotificationPresentationDecider.decide(
      soundEnabled: sound, respectFocus: respectFocus, inFocus: inFocus,
      coalesceEnabled: coalesce, recentPresentationsMs: recentPresentationsMs, nowMs: nowMs)
    if decision.banner { recentPresentationsMs.append(nowMs) }
    var opts: UNNotificationPresentationOptions = []
    if decision.banner { opts.insert(.banner) }
    if decision.sound { opts.insert(.sound) }
    if decision.badge { opts.insert(.badge) }
    return opts
  }

  /// User clicked notification (default tap) OR a banner action button:
  ///
  /// - `UNNotificationDefaultActionIdentifier` (banner body tap) → Track 5
  ///   / S7 H.6 deep-link: switch workspace + activate Team tab + signal
  ///   scroll-to/highlight + eager-fetch the message via `tickOnce`.
  /// - `dm.reply` (Track 5 / S8 T6) → same deep-link path PLUS
  ///   `WindowState.focusReplyField = true` so TeamView observes the flag
  ///   and signals reply-focus intent.
  /// - `dm.markDone` (Track 5 / S8 T6) → does NOT open the app; dispatches
  ///   `DirectMessageInboxReader.markDone(messageID:)` which runs the
  ///   optimistic local UPDATE + server PATCH + retry-queue flag flow.
  /// - Anything else → no-op (unknown action / category from a future
  ///   server / forward-compat).
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    let userInfo = response.notification.request.content.userInfo
    // `leaf_workspace_id` is carried by every push family we route here
    // (DM + M027 invite request/approved). `leaf_message_id` is DM-only;
    // gated per-branch below so invite Approve/Decline actions don't get
    // dropped by an over-tight entry guard.
    guard let workspaceID = userInfo["leaf_workspace_id"] as? String else {
      return
    }
    let messageID = userInfo["leaf_message_id"] as? String

    switch response.actionIdentifier {
    case NotificationCategoryRegistry.replyActionID:
      // Reply action — same deep-link as default tap, plus focusReplyField
      // signal so TeamView observers can hand focus to the reply UI.
      // The reply textfield itself ships in a later Track (S7 deferred
      // inline reply to Track 6); until then the flag plumbing is
      // exercised by tests + scroll/highlight surfaces alone.
      guard let messageID else { return }
      await deepLinkToMessage(
        workspaceID: workspaceID,
        messageID: messageID,
        focusReply: true
      )

    case NotificationCategoryRegistry.inviteApproveActionID:
      // M027 — Approve action. Opens app + scrolls to Settings → Workspace
      // → Pending requests. The actual approve flow runs in-app because
      // ECDH+seal requires the local keystore to be unlocked.
      await deepLinkToPendingQueue(workspaceID: workspaceID)

    case NotificationCategoryRegistry.inviteDeclineActionID:
      // M027 — Decline action. Opens app + scrolls to Pending requests.
      // The actual decline call is also in-app for symmetry.
      await deepLinkToPendingQueue(workspaceID: workspaceID)

    case NotificationCategoryRegistry.markDoneActionID:
      // Mark Done — explicitly does NOT open the app or modify
      // WindowState. Dispatches into the inbox reader which owns the
      // optimistic local UPDATE + server PATCH + retry-queue path.
      // Switching the active workspace is intentionally avoided here:
      // the user did not request a context switch (they tapped Done
      // from a banner that may be cross-workspace) and the reader's
      // markDone path operates on message_id directly.
      guard let messageID else { return }
      await Self.directMessageInboxReader?.markDone(messageID: messageID)

    case UNNotificationDefaultActionIdentifier:
      // Default tap (banner body). Three families:
      //   DM (`leaf.dm.<kind>`) → S7 H.6 deep-link with scroll/highlight.
      //   `leaf.invite.request` (admin-side) → PendingRequestsSection.
      //   `leaf.invite.approved` (invitee-side) → switch + Team view.
      let categoryID = response.notification.request.content.categoryIdentifier
      switch categoryID {
      case NotificationCategoryRegistry.inviteRequestCategoryID:
        await deepLinkToPendingQueue(workspaceID: workspaceID)
      case NotificationCategoryRegistry.inviteApprovedCategoryID:
        await deepLinkToWorkspace(workspaceID: workspaceID)
      default:
        // DM family — keep S7 H.6 contract.
        guard let messageID else { return }
        await deepLinkToMessage(
          workspaceID: workspaceID,
          messageID: messageID,
          focusReply: false
        )
      }

    default:
      // Unknown action identifier — forward-compat no-op.
      break
    }
  }

  /// Track 5 / S7 H.6 deep-link path shared by default-tap and dm.reply.
  /// Switches active workspace if needed, drives UI to .team, sets
  /// pendingMessageID for TeamView scroll/highlight, and (for dm.reply)
  /// raises focusReplyField. Eager-fetches the message via tickOnce so
  /// the local mirror has the row by the time scrollTo fires.
  @MainActor
  private func deepLinkToMessage(workspaceID: String, messageID: String, focusReply: Bool) async {
    if Self.activeWorkspaceStore?.activeWorkspaceID != workspaceID {
      Self.activeWorkspaceStore?.setActive(workspaceID)
    }
    Self.windowState?.section = .team
    Self.windowState?.pendingWorkspaceID = workspaceID
    Self.windowState?.pendingMessageID = messageID
    if focusReply {
      Self.windowState?.focusReplyField = true
    }
    // Eager-fetch the message so it is in the local mirror by the time
    // TeamView's scrollTo fires. If the row already exists this is a no-op.
    await Self.directMessageInboxReader?.tickOnce(
      workspaceID: workspaceID, forMessageID: messageID
    )
  }

  /// M027 invite-redesign — deep-link from `leaf.invite.request` push action
  /// (Approve / Decline) to Settings → Workspace → Pending requests.
  @MainActor
  private func deepLinkToPendingQueue(workspaceID: String) async {
    if Self.activeWorkspaceStore?.activeWorkspaceID != workspaceID {
      Self.activeWorkspaceStore?.setActive(workspaceID)
    }
    Self.windowState?.section = .settings
    Self.windowState?.pendingWorkspaceID = workspaceID
    // User reviews + approves/declines in PendingRequestsSection — the
    // section's .onAppear refreshes the queue automatically.
  }

  /// `leaf.invite.approved` invitee-side default tap — switch into the
  /// freshly-joined workspace and land in Team view. The workspace was
  /// materialised locally by `JoinRequestService.acceptApproved` before
  /// this notification ever fires, so `setActive` resolves cleanly.
  private func deepLinkToWorkspace(workspaceID: String) async {
    if Self.activeWorkspaceStore?.activeWorkspaceID != workspaceID {
      Self.activeWorkspaceStore?.setActive(workspaceID)
    }
    Self.windowState?.section = .team
    Self.windowState?.pendingWorkspaceID = workspaceID
  }
}

/// A view wrapper so that `@Environment(\.openWindow)` resolves inside a `CommandGroup`.
private struct OpenSettingsCommand: View {
  let windowState: WindowState
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("Settings…") {
      windowState.section = .settings
      NSApp.activate(ignoringOtherApps: true)
      openWindow(id: "main")
    }
    .keyboardShortcut(",", modifiers: .command)
  }
}

#if DEBUG
  /// Track 2 / D1 — debug-only ⌘⌥T menu item that opens TokensPreviewScreen.
  /// Hidden from release builds (#if DEBUG), but the files compile for tests.
  private struct OpenTokensPreviewCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
      Button("Tokens Preview") {
        openWindow(id: "tokens-preview")
      }
      .keyboardShortcut("t", modifiers: [.command, .option])
    }
  }
#endif
