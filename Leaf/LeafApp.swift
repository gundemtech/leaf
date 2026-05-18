//
//  LeafApp.swift
//  Leaf
//

import SwiftUI
import UserNotifications
import os
import LeafCore
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
    /// Track 5 / S4 — DM send + inbox + APNs registration readers.
    @State private var directMessageSendReader: DirectMessageSendReader
    @State private var directMessageInboxReader: DirectMessageInboxReader
    @State private var apnsRegistrationReader: APNsRegistrationReader
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
    @State private var windowState = WindowState()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Phase 3.4.5 — материализуем db.key из main app's Keychain group ДО `agent.register()`.
        // Helpers (LeafAgent/LeafMCP) живут в other default Keychain access groups (без shared
        // entitlement они не видят main app's group), поэтому если LeafAgent стартанёт первым,
        // он сгенерит свой random key и разломает alpha.2 БД, зашифрованную main app's K1.
        // Eager call здесь решает race детерминированно.
        #if LEAF_PROD
        do {
            _ = try FileKeyStore.fetchOrCreate()
            FileKeyStore.cleanupLegacyKeychainBestEffort()
        } catch {
            // Не падаем — popover/Settings покажет error через InsightsReader state machine.
            leafAppLogger.error("FileKeyStore.fetchOrCreate failed at init: \(String(describing: error), privacy: .public)")
        }
        #endif

        // Register Derived Insights provider once per app launch. Прямой
        // import + register здесь возможен т.к. app target гарантированно
        // получает флаг LEAF_PROD из xcconfig (в отличие от SPM
        // dependencies, куда флаг не пропагируется).
        #if LEAF_PROD
        DerivedInsightsFactory.register { LeafCorePrivate.ProdInsights(database: $0) }
        #endif

        // D13 (Phase 3.1) — explicit _state = State(initialValue:) pattern для
        // ordered initialization @State properties (нужен для post-init register
        // call ниже). LaunchAgentService init синхронно reads SMAppService.status
        // → нужна детерминированная сборка inline.
        let agent = LaunchAgentService()
        _launchAgent = State(initialValue: agent)
        _updater = State(initialValue: UpdaterController())

        // Track 5 S2 Task 10 — explicit init pair: ActiveWorkspaceStore владеет
        // active-workspace UD ключом, WorkspaceReader подписывается на неё. Оба
        // @MainActor — App.init implicitly @MainActor, конструкторы OK.
        let active = ActiveWorkspaceStore()
        _activeWorkspaceStore = State(initialValue: active)
        _workspaceReader = State(initialValue: WorkspaceReader(activeStore: active))

        // Track 5 / S3 — SupabaseClient is the first Mac client primitive talking to Supabase.
        // baseURL + anonKey read from Info.plist (xcconfig substitution).
        // Track 5 / S4 — adds SupabaseSessionStore for refresh_token persistence (closes I3).
        let supabaseSessionStore = SupabaseSessionStore(at: TeamKeystore.defaultRoot())
        let supabase = SupabaseClient(
            baseURL: SupabaseConfig.baseURL(from: Bundle.main),
            anonKey: SupabaseConfig.anonKey(from: Bundle.main),
            identity: { try IdentityService.ensureLocalIdentity(at: TeamKeystore.defaultRoot()) },
            sessionStore: supabaseSessionStore
        )
        _supabaseClient = State(initialValue: supabase)
        _inviteOutboxReader = State(initialValue: InviteOutboxReader(supabase: supabase))
        _inviteAcceptReader = State(initialValue: InviteAcceptReader(supabase: supabase))

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

        // Track 5 / S5 — broadcast + mirror readers + 30s tick scheduling
        // (driven by OrganizationView .task per S4 DM inbox precedent).
        _teamEventBroadcastReader = State(initialValue: TeamEventBroadcastReader(supabase: supabase))
        _teamEventMirrorReader = State(initialValue: TeamEventMirrorReader(supabase: supabase))

        // Track 5 / S6 T13 — cross-post composition wiring.
        // SlackChannels + LinearTeams use Stub providers (returns empty arrays)
        // in non-LEAF_PROD builds; production HTTP impls live в LeafCorePrivate
        // (gitignored moat) and are swapped в via #if LEAF_PROD when present.
        // For initial T13 ship, all builds use Stub — Send sheet pickers show
        // empty list; production provider wiring is incremental polish.
        _slackChannelsReader = State(initialValue: SlackChannelsReader(provider: StubSlackChannelsProvider()))
        _linearTeamsReader = State(initialValue: LinearTeamsReader(provider: StubLinearTeamsProvider()))

        // LinearScopesReader wraps LinearScopesService (DB-backed) + adapter
        // bridging the Sendable `LinearOAuthReauthorizing` protocol to the
        // app-target `LinearOAuthService.connect()` flow (which opens browser).
        // _linearOAuth.wrappedValue used here because Swift can't prove `self`
        // is initialized for `self.linearOAuth` access before all @State props
        // are set — the underlying storage IS initialized at declaration.
        let linearScopesService = LeafApp.makeLinearScopesService()
        let linearReauth = LinearOAuthReauthorizeAdapter(service: _linearOAuth.wrappedValue)
        _linearScopesReader = State(initialValue: LinearScopesReader(
            service: linearScopesService ?? LinearScopesService(grantedOverride: []),
            reauthorizer: linearReauth
        ))

        // LinearUsersResolver — fuzzy assignee resolution (T9). Stub provider
        // returns empty list in dev; production HTTP impl via LeafCorePrivate.
        _linearUsersResolver = State(initialValue: LinearUsersResolver(
            provider: StubLinearGraphQLProvider()
        ))

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
        let attachmentResolver: AttachmentMetadataResolver?
        let teamFeedQueryDB: LeafCore.Database?
        if let resolverDB = LeafApp.makeDatabaseForTeamFeed() {
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
            _teamFeedReader = State(initialValue: TeamFeedReader(
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
                _teamFeedReader = State(initialValue: TeamFeedReader(
                    queryService: queryService,
                    memberResolver: memberResolver
                ))
            } else {
                // Genuine cold-start broken state — fatalError keeps the crash
                // localized to init rather than a confusing runtime null deref.
                fatalError("LeafApp init: cannot open SQLCipher database for TeamFeed")
            }
        }

        _crossPostLogReader = State(initialValue: CrossPostLogReader(supabase: supabase))
        _feedFilterStore = State(initialValue: FeedFilterStore(userDefaults: .standard))

        // Realtime substrate. Driver = actor with URLSession.shared by default.
        let realtimeDriver = RealtimeWebSocketDriver()
        let realtimeURL = LeafApp.realtimeURL(forSupabase: supabase)

        // Decryption closures — Phase H ships the substrate; the wire→plaintext
        // mapping requires keystore lookup + AES-GCM decode which is identical to
        // existing TeamEventMirrorService.tick / DirectMessageInboxService.tick
        // logic but isn't currently exposed as a clean per-row closure. Until
        // that refactor lands (carryover), the closures throw a marker error and
        // the Realtime path silently drops pushes (see LeafRealtimeService.dispatch).
        // The 30s polling tick on OrganizationView already covers latency-tolerant
        // delivery; Realtime is a latency optimisation, not a delivery requirement.
        let teamEventDecryptor: @Sendable (SupabaseTeamEventRow) async throws -> TeamEventMirrorRow = { _ in
            throw NSError(domain: "S7.RealtimeDecrypt", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "TeamEvent decrypt wiring deferred to signed-build smoke (G19); falls back to 30s mirror tick"
            ])
        }
        let directMessageDecryptor: @Sendable (SupabaseDirectMessageRow) async throws -> DirectMessageMirrorRow = { _ in
            throw NSError(domain: "S7.RealtimeDecrypt", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "DirectMessage decrypt wiring deferred to signed-build smoke (G19); falls back to 30s inbox tick"
            ])
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

        // D1 — idempotent register для post-update relaunch restoration.
        // Sparkle relaunch'ает app после bundle replace + cold launch без update flow:
        // если уже enabled (status restored launchd) — register() filter "already
        // registered" в LaunchAgentService предотвращает spurious red error.
        // Multi-process choreography: SMAppService.register triggers launchd to
        // SIGTERM old agent (если другой binary path) и start new agent — existing
        // SignalHandlers (Agent.swift:131) flush WAL gracefully. См. UpdaterController
        // doc-comment про D14 deviation от master plan A2 D2.
        if !agent.isEnabled {
            agent.register()
        }
    }

    var body: some Scene {
        Window("Leaf", id: "main") {
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
                .environment(workspaceReader)            // Track 5 S2 Task 10
                .environment(activeWorkspaceStore)       // Track 5 S2 Task 10
                // Track 5 / S3 — SupabaseClient is an actor (not @Observable), injected directly
                // into readers via constructor. UI surfaces consume readers, not the client directly.
                .environment(inviteOutboxReader)
                .environment(inviteAcceptReader)
                .environment(directMessageSendReader)   // Track 5 / S4
                .environment(directMessageInboxReader)  // Track 5 / S4
                .environment(apnsRegistrationReader)    // Track 5 / S4
                .environment(shareRulesReader)          // Track 5 / S5
                .environment(teamEventBroadcastReader)  // Track 5 / S5
                .environment(teamEventMirrorReader)     // Track 5 / S5
                .environment(slackChannelsReader)       // Track 5 / S6
                .environment(linearTeamsReader)         // Track 5 / S6
                .environment(linearScopesReader)        // Track 5 / S6
                // LinearUsersResolver is an actor (not @Observable); plumbed via
                // explicit closure into Send sheet from OrganizationView call site.
                .environment(\.linearUsersResolver, linearUsersResolver)
                .environment(teamFeedReader)            // Track 5 / S7 H.3
                .environment(crossPostLogReader)        // Track 5 / S7 H.3
                .environment(feedFilterStore)           // Track 5 / S7 H.3
                .environment(realtimeService)           // Track 5 / S7 H.3
                // AttachmentMetadataResolver is an actor (not @Observable);
                // custom EnvironmentKey threads optional resolver to TeamView.
                .environment(\.attachmentMetadataResolver, attachmentMetadataResolver)
                .environment(memberRemovalReader)  // Phase 5.3.E
                .environment(pendingInvitesReader)  // Phase 5.5.C
                .environment(inviteURLHandler)  // Phase 5.5.B
                .environment(windowState)
                .onAppear {
                    inviteURLHandler.wire(acceptReader: inviteAcceptReader,
                                          outboxReader: inviteOutboxReader)
                }
                .onOpenURL { url in
                    inviteURLHandler.handle(url)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    // Phase 5.5.B — invitee comes back to Leaf after admin sent invite link;
                    // probe clipboard для auto-fetch без manual paste step. Deep-link path
                    // (`.onOpenURL`) covers click-to-open; this covers Cmd-Tab-from-chat-app.
                    guard newPhase == .active else { return }
                    if case .inviteURL(let url) = inviteURLHandler.probeClipboard() {
                        inviteAcceptReader.fetch(inviteURL: url)
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
            MenuBarContent()
                .environment(launchAgent)
                .environment(watchedFolders)
                .environment(permissions)
                .environment(updater)
                .environment(reader)
                .environment(workspaceReader)            // Track 5 S2 Task 10
                .environment(activeWorkspaceStore)       // Track 5 S2 Task 10
                .environment(inviteAcceptReader)
                .environment(inviteURLHandler)  // Phase 5.5.B
                .environment(windowState)
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
            leafAppLogger.error("makeGitHubScopesService failed: \(String(describing: error), privacy: .public)")
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
            leafAppLogger.error("makeLinearScopesService failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Team feed DB bootstrap + Realtime URL (Track 5 / S7 H.1)

    /// Same DB-open shape as `makeGitHubScopesService` — used by
    /// `AttachmentMetadataResolver` (reads events table via json_extract) and
    /// `TeamFeedQueryService` (reads messages_mirror + team_events_mirror via
    /// UNION). Returns `nil` on failure so callers can fall back gracefully.
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
            leafAppLogger.error("makeDatabaseForTeamFeed failed: \(String(describing: error), privacy: .public)")
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
        case "http":  components.scheme = "ws"
        case "https": components.scheme = "wss"
        default:      components.scheme = "wss"
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
            leafAppLogger.error("makeSlackScopesService failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// `applicationShouldHandleReopen` нужен чтобы клик по Dock-иконке (после
/// того как юзер закрыл окно) снова открывал главное окно. Без этого SwiftUI
/// `Window` не реагирует на reopen — менюбар-присутствие "съедает" событие.
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Найти существующее SwiftUI Window (id="main") по identifier и поднять.
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
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                NSApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func application(_ application: NSApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
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

    func application(_ application: NSApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        leafAppLogger.error("APNs register failed: \(String(describing: error), privacy: .public)")
    }

    func application(_ application: NSApplication,
                     didReceiveRemoteNotification userInfo: [String: Any]) {
        // Spec §10.3 payload: leaf_message_id + leaf_workspace_id.
        guard let messageID = userInfo["leaf_message_id"] as? String,
              let workspaceID = userInfo["leaf_workspace_id"] as? String else {
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
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        return [.banner, .sound, .badge]
    }

    /// User clicked notification → eager-fetch the referenced message AND
    /// (Track 5 / S7 H.6) deep-link the UI to the Team tab, switch active
    /// workspace if needed, and signal TeamView to scroll-to/highlight the
    /// matching message cell via `WindowState.pendingMessageID`.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        guard let messageID = userInfo["leaf_message_id"] as? String,
              let workspaceID = userInfo["leaf_workspace_id"] as? String else {
            return
        }
        // Switch active workspace + drive UI to Team tab + signal scroll-to.
        // Done before tickOnce so the UI renders pre-fetch (graceful empty
        // until decryption lands the row).
        if Self.activeWorkspaceStore?.activeWorkspaceID != workspaceID {
            Self.activeWorkspaceStore?.setActive(workspaceID)
        }
        Self.windowState?.section = .team
        Self.windowState?.pendingWorkspaceID = workspaceID
        Self.windowState?.pendingMessageID = messageID

        // Eager-fetch the message so it is in the local mirror by the time
        // TeamView's scrollTo fires. If the row already exists this is a no-op.
        await Self.directMessageInboxReader?.tickOnce(
            workspaceID: workspaceID, forMessageID: messageID
        )
    }
}

/// View-обёртка чтобы `@Environment(\.openWindow)` резолвился внутри `CommandGroup`.
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
/// Track 2 / D1 — debug-only ⌘⌥T menu item открывающее TokensPreviewScreen.
/// Скрывается из release builds (#if DEBUG), но файлы компилятся для тестов.
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
