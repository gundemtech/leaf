import Foundation
import AppKit
import os
import LeafCore
#if LEAF_PROD
import LeafCorePrivate
#endif

// Агент — command-line daemon, запускается LaunchAgent'ом через SMAppService.
// Использует sync @main + внутренние Task'и для async работы, чтобы
// `RunLoop.main.run()` в конце блокировал на main thread (mandatory для
// NSWorkspace notifications).

@main
enum AgentMain {
    static func main() {
        #if LEAF_PROD
        let databaseConfig = ProdConfigs.database
        let agentThresholds = ProdConfigs.agent
        let usingProdConfig = true
        let databaseEncryption: EncryptionOptions? = EncryptionOptions(
            keyProvider: .callback { @Sendable in
                try FileKeyStore.fetchOrCreate()
            },
            preKeyPragmas: ProdConfigs.sqlcipherPragmasPreKey,
            postKeyPragmas: ProdConfigs.sqlcipherPragmasPostKey
        )
        #else
        let databaseConfig = DatabaseConfig.weakDefaults
        let agentThresholds = AgentThresholds.weakDefaults
        let usingProdConfig = false
        let databaseEncryption: EncryptionOptions? = nil
        #endif

        agentLogger.info("Leaf agent starting (prodConfig=\(usingProdConfig, privacy: .public))")

        // Database
        let dbURL = DatabasePath.defaultURL()
        let database: Database
        do {
            database = try Database.openForWrite(at: dbURL, config: databaseConfig, encryption: databaseEncryption)
            agentLogger.info("Database opened at \(dbURL.path, privacy: .public)")
        } catch {
            agentLogger.critical("Failed to open database: \(error.localizedDescription, privacy: .public)")
            exit(1)
        }

        // Writer + collectors + maintenance scheduler. Retain'им в статичных globals
        // чтобы не собралось по ARC до срабатывания SIGTERM handler'а.
        let writer = EventWriter(database: database, thresholds: agentThresholds)

        // Phase 4.10.B — classifier injection: prod (moat preset) для signed
        // build, public empty stub для dev/CI. Empty fallback корректен:
        // collector просто не enrich'ит payload window_title (всё → L1).
        let classifier: any AppCategoryClassifier = {
            #if LEAF_PROD
            return ProdAppCategoryClassifier()
            #else
            return EmptyAppCategoryClassifier()
            #endif
        }()
        let activeAppCollector = ActiveAppCollector(
            writer: writer,
            blocklist: Blocklist.phase1Default,
            policy: DefaultAttentionGranularityPolicy(classifier: classifier),
            classifier: classifier,
            pollIntervalSec: agentThresholds.attentionWindowPollIntervalSec
        )
        let idleCollector = IdleCollector(writer: writer, thresholds: agentThresholds)
        let maintenance = MaintenanceScheduler(
            database: database,
            walCheckpointIntervalSec: databaseConfig.walCheckpointIntervalSec,
            retentionSweepIntervalSec: agentThresholds.retentionSweepIntervalSec,
            retentionDays: agentThresholds.retentionDays,
            logger: maintenanceLogger
        )

        // Phase 2.3 — Claude Code AI collaboration collector.
        // Parser injection: prod schema-mapping в moat, public Stub для dev/CI.
        let claudeCodeParser: any ClaudeCodeJSONLParsing = {
            #if LEAF_PROD
            return ClaudeCodeJSONLParser()
            #else
            return StubClaudeCodeJSONLParser()
            #endif
        }()
        let projectsRoot = URL(
            fileURLWithPath: (agentThresholds.claudeCodeProjectsPath as NSString).expandingTildeInPath
        )
        let claudeCodeCollector = ClaudeCodeCollector(
            database: database,
            parser: claudeCodeParser,
            projectsRoot: projectsRoot,
            intervalSec: agentThresholds.aiCollectIntervalSec,
            backfillWindowDays: agentThresholds.backfillWindowDays,
            logger: claudeCodeLogger
        )

        // Track-6 P1 (Task 17) — hook bridge listener wiring. The bridge
        // (`leaf-hook-bridge`) writes line-delimited envelopes to a
        // unix-domain socket; we accept, parse, and forward to the collector
        // which (a) writes RawEvents and (b) records each tool_use_id so the
        // subsequent jsonl tick can dedup. LEAF_PROD gate: the parser +
        // listener live in LeafCorePrivate (moat); public stub builds skip
        // the wiring entirely.
        #if LEAF_PROD
        let hookParser = ClaudeCodeHookParser()
        let hookSocketPath = ("~/Library/Application Support/Leaf/hooks.sock" as NSString)
            .expandingTildeInPath
        let hookListener = ClaudeCodeHookSocketListener(socketPath: hookSocketPath) { envelope in
            let events = hookParser.parse(envelope: envelope)
            if !events.isEmpty {
                Task { await claudeCodeCollector.ingestHookEvents(events) }
            }
        }
        do {
            try hookListener.start()
            claudeCodeLogger.info("hook listener started on \(hookSocketPath, privacy: .public)")
        } catch {
            claudeCodeLogger.error(
                "hook listener start failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        #endif

        // Phase 2.4 — FSEvents content collector для watched folders.
        // Router injection: prod (ignore-list + L4/L5 + coalesce) в moat,
        // public Stub возвращает .filtered always → CI builds работают.
        let fsEventsRouter: any FSEventsRouting = {
            #if LEAF_PROD
            return FSEventsRouterProd(
                ignoreRules: ProdConfigs.fsEventsIgnoreRules,
                coalesceWindowSec: agentThresholds.fsEventsCoalesceWindowSec
            )
            #else
            return StubFSEventsRouter()
            #endif
        }()
        let fsEventsCollector = FSEventsCollector(
            database: database,
            router: fsEventsRouter,
            reconfigPollSec: agentThresholds.fsEventsReconfigPollSec,
            latencySec: agentThresholds.fsEventsLatencySec,
            darwinNotificationName: agentThresholds.fsEventsRestartTriggerName,
            logger: fsEventsLogger
        )

        // Phase 4.2 — Linear GraphQL polling collector.
        // Provider injection: prod (paginated query + retry + complexity budget)
        // в moat, public Stub no-op для CI/dev. clientID empty → graceful skip
        // (collector не стартует). Refresher переехал в LeafCore (Phase 4.2 D1).
        let linearProvider: any LinearGraphQLProvider = {
            #if LEAF_PROD
            return ProdLinearGraphQLProvider()
            #else
            return StubLinearGraphQLProvider()
            #endif
        }()
        let linearCollector: LinearCollector? = {
            guard !agentThresholds.linearOAuthClientID.isEmpty else {
                linearLogger.info("Linear OAuth client_id not configured — collector disabled")
                return nil
            }
            let refresher = LinearTokenRefresher(
                database: database,
                clientID: agentThresholds.linearOAuthClientID
            )
            return LinearCollector(
                database: database,
                provider: linearProvider,
                refresher: refresher,
                intervalSec: agentThresholds.linearPollIntervalSec,
                backfillWindowDays: agentThresholds.backfillWindowDays,
                logger: linearLogger
            )
        }()

        // Phase Track-3 D1 — Linear warm + cold tiers. Both depend on a
        // working OAuth integration (same gate as hot LinearCollector — skip
        // if client_id is empty). Reuse the same `linearProvider` instance —
        // protocol now carries fetchWarmState / fetchColdState.
        let (linearWarmCollector, linearWarmScheduler, linearColdCollector, linearColdScheduler): (
            LinearWarmCollector?, LinearWarmScheduler?,
            LinearColdCollector?, LinearColdScheduler?
        ) = {
            guard !agentThresholds.linearOAuthClientID.isEmpty else {
                return (nil, nil, nil, nil)
            }
            let warmRefresher = LinearTokenRefresher(
                database: database, clientID: agentThresholds.linearOAuthClientID)
            let coldRefresher = LinearTokenRefresher(
                database: database, clientID: agentThresholds.linearOAuthClientID)
            let warm = LinearWarmCollector(
                database: database, provider: linearProvider,
                refresher: warmRefresher,
                intervalSec: agentThresholds.linearWarmPollIntervalSec,
                backfillWindowDays: agentThresholds.backfillWindowDays,
                logger: linearLogger)
            let warmSched = LinearWarmScheduler(
                collector: warm,
                intervalSec: agentThresholds.linearWarmPollIntervalSec,
                logger: linearLogger)
            let cold = LinearColdCollector(
                database: database, provider: linearProvider,
                refresher: coldRefresher,
                intervalSec: agentThresholds.linearColdPollIntervalSec,
                logger: linearLogger)
            let coldSched = LinearColdScheduler(
                database: database, collector: cold,
                workspaceIDProvider: {
                    // `try?` collapses throws+Optional → IntegrationRecord?.
                    (try? database.readIntegration(provider: .linear))?.workspaceID
                },
                logger: linearLogger)
            return (warm, warmSched, cold, coldSched)
        }()

        // Phase 4.3 — GitHub REST events polling collector.
        // Mirror Linear: prod parser в moat (ProdGitHubAPIProvider — REST event
        // mapping + ADR-010 enforcement), public Stub no-op для CI/dev. Empty
        // clientID → graceful skip (collector не стартует — нет OAuth App).
        let githubProvider: any GitHubAPIProvider = {
            #if LEAF_PROD
            return ProdGitHubAPIProvider()
            #else
            return StubGitHubAPIProvider()
            #endif
        }()
        let githubCollector: GitHubCollector? = {
            guard !agentThresholds.githubOAuthClientID.isEmpty else {
                githubLogger.info("GitHub OAuth client_id not configured — collector disabled")
                return nil
            }
            let refresher = GitHubTokenRefresher(
                database: database,
                clientID: agentThresholds.githubOAuthClientID
            )
            return GitHubCollector(
                database: database,
                provider: githubProvider,
                refresher: refresher,
                intervalSec: agentThresholds.githubPollIntervalSec,
                backfillWindowDays: agentThresholds.backfillWindowDays,
                logger: githubLogger
            )
        }()

        // Phase Track-3 D2 — GitHub warm + cold tiers + ScopesService actor.
        // Same gating predicate as hot collector (skip if client_id is empty).
        // ScopesService is shared between warm + cold (both inject scopeService:)
        // and stored in AgentLifetime so UI/observer code can read scope state.
        let githubScopesService: GitHubScopesService? = {
            guard !agentThresholds.githubOAuthClientID.isEmpty else { return nil }
            return GitHubScopesService(database: database)
        }()
        let (githubWarmCollector, githubWarmScheduler, githubColdCollector, githubColdScheduler): (
            GitHubWarmCollector?, GitHubWarmScheduler?,
            GitHubColdCollector?, GitHubColdScheduler?
        ) = {
            guard !agentThresholds.githubOAuthClientID.isEmpty,
                  let scopes = githubScopesService else {
                return (nil, nil, nil, nil)
            }
            let warmRefresher = GitHubTokenRefresher(
                database: database, clientID: agentThresholds.githubOAuthClientID)
            let coldRefresher = GitHubTokenRefresher(
                database: database, clientID: agentThresholds.githubOAuthClientID)
            let warm = GitHubWarmCollector(
                database: database, provider: githubProvider,
                refresher: warmRefresher,
                scopeService: scopes,
                intervalSec: agentThresholds.githubWarmPollIntervalSec,
                logger: githubLogger)
            let warmSched = GitHubWarmScheduler(
                collector: warm,
                intervalSec: agentThresholds.githubWarmPollIntervalSec,
                logger: githubLogger)
            let cold = GitHubColdCollector(
                database: database, provider: githubProvider,
                refresher: coldRefresher,
                scopeService: scopes,
                intervalSec: agentThresholds.githubColdPollIntervalSec,
                logger: githubLogger)
            let coldSched = GitHubColdScheduler(
                database: database, collector: cold,
                loginProvider: {
                    (try? database.readIntegration(provider: .github))?.workspaceName
                },
                logger: githubLogger)
            return (warm, warmSched, cold, coldSched)
        }()

        // Phase 4.4 — Slack Web API polling collector.
        // Mirror Linear/GitHub: prod parser в moat (ProdSlackAPIProvider — search.messages
        // + users.profile.get mapping + ADR-010 enforcement: bodies/permalinks discard'ятся
        // pre-RawEvent), public Stub no-op для CI/dev. Empty clientID → graceful skip.
        let slackProvider: any SlackAPIProvider = {
            #if LEAF_PROD
            return ProdSlackAPIProvider()
            #else
            return StubSlackAPIProvider()
            #endif
        }()
        let slackCollector: SlackCollector? = {
            guard !agentThresholds.slackOAuthClientID.isEmpty else {
                slackLogger.info("Slack OAuth client_id not configured — collector disabled")
                return nil
            }
            let refresher = SlackTokenRefresher(
                database: database,
                clientID: agentThresholds.slackOAuthClientID
            )
            return SlackCollector(
                database: database,
                provider: slackProvider,
                refresher: refresher,
                intervalSec: agentThresholds.slackPollIntervalSec,
                backfillWindowDays: agentThresholds.backfillWindowDays,
                logger: slackLogger
            )
        }()

        // Phase Track-3 D3 — Slack warm + cold tiers + ScopesService actor.
        // Same gating predicate as hot collector (skip if client_id is empty).
        // ScopesService is shared between warm + cold (both inject scopes:)
        // and stored in AgentLifetime so UI/observer code can read scope state.
        let slackScopesService: SlackScopesService? = {
            guard !agentThresholds.slackOAuthClientID.isEmpty else { return nil }
            return SlackScopesService(database: database)
        }()
        let (slackWarmCollector, slackWarmScheduler, slackColdCollector, slackColdScheduler): (
            SlackWarmCollector?, SlackWarmScheduler?,
            SlackColdCollector?, SlackColdScheduler?
        ) = {
            guard !agentThresholds.slackOAuthClientID.isEmpty,
                  let scopes = slackScopesService else {
                return (nil, nil, nil, nil)
            }
            // Per-tier refresher instances (mirror GitHub D2 — refresher is cheap,
            // and avoids any actor-isolation surprises between tiers).
            let warmRefresher = SlackTokenRefresher(
                database: database,
                clientID: agentThresholds.slackOAuthClientID
            )
            let coldRefresher = SlackTokenRefresher(
                database: database,
                clientID: agentThresholds.slackOAuthClientID
            )
            // workspaceID format is "<team>:<user>". Collectors prefer the
            // integration record (single source of truth) and only fall back to
            // these closures if the record's format is malformed — passing
            // matching readers keeps semantics consistent with hot collector.
            let workspaceIDProvider: @Sendable () -> String? = {
                guard let id = (try? database.readIntegration(provider: .slack))?.workspaceID
                else { return nil }
                let parts = id.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].isEmpty else { return nil }
                return String(parts[0])
            }
            let userIDProvider: @Sendable () -> String? = {
                guard let id = (try? database.readIntegration(provider: .slack))?.workspaceID
                else { return nil }
                let parts = id.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[1].isEmpty else { return nil }
                return String(parts[1])
            }
            let warm = SlackWarmCollector(
                database: database,
                provider: slackProvider,
                tokenRefresher: warmRefresher,
                scopes: scopes,
                workspaceIDProvider: workspaceIDProvider,
                userIDProvider: userIDProvider,
                clock: { Date() },
                logger: slackLogger
            )
            let warmSched = SlackWarmScheduler(
                collector: warm,
                intervalSec: agentThresholds.slackWarmPollIntervalSec,
                logger: slackLogger
            )
            let cold = SlackColdCollector(
                database: database,
                provider: slackProvider,
                tokenRefresher: coldRefresher,
                scopes: scopes,
                workspaceIDProvider: workspaceIDProvider,
                userIDProvider: userIDProvider,
                clock: { Date() },
                logger: slackLogger
            )
            let coldSched = SlackColdScheduler(
                database: database,
                collector: cold,
                workspaceIDProvider: workspaceIDProvider,
                logger: slackLogger
            )
            return (warm, warmSched, cold, coldSched)
        }()

        // Phase Track-4 S1 — Architecture catch-up collectors. Substrate-only
        // Layer A observers (Calendar / Focus / system state / spaces). No
        // OAuth, no external API. Calendar / Focus are TCC-gated and degrade
        // to no-op on denial; system state and spaces require no permissions.
        let calendarCollector = CalendarCollector(
            writer: writer,
            pollIntervalSec: agentThresholds.calendarPollIntervalSec
        )
        let focusModeCollector = FocusModeCollector(
            writer: writer,
            pollIntervalSec: agentThresholds.focusModePollIntervalSec
        )
        let systemStateCollector = SystemStateCollector(writer: writer)
        let spacesCollector = SpacesCollector(
            writer: writer,
            coalesceWindowSec: agentThresholds.spaceTransitionCoalesceWindowSec
        )

        // Phase Track-4 S2 — AppleScript surface. Public substrate ships an
        // empty adapter registry; the moat-side ProdAppleScriptAdapterRegistry
        // (LeafCorePrivate) wires the per-app adapters under LEAF_PROD.
        // Track-6 P3 — browser adapters require a DomainAllowListReader so the
        // registry now accepts one and forwards it to ProdSafari/Chrome/ArcAdapter.
        let appleScriptBridge = AppleScriptBridge.production()
        let appleScriptPermissionStore = AppleScriptPermissionStore()
        let localAppsStore = LocalAppsStore()
        let appleScriptRegistry: any AppleScriptAdapterRegistry = {
            #if LEAF_PROD
            let allowListReader = DBDomainAllowListReader(pool: database.pool)
            return ProdAppleScriptAdapterRegistry(allowListReader: allowListReader)
            #else
            return EmptyAppleScriptAdapterRegistry()
            #endif
        }()
        let appleScriptCollector = AppleScriptCollector(
            bridge: appleScriptBridge,
            permissionStore: appleScriptPermissionStore,
            localAppsStore: localAppsStore,
            registry: appleScriptRegistry,
            writer: writer
        )

        // Phase Track-4 S3 — System observers + intensity. SystemObserversStore
        // shares cross-process suite "tech.gundem.leaf" (LocalAppsStore pattern).
        // InputMonitoringPermissionStore caches 24h denial backoff. CGEventTap
        // gates on systemStateCollector.isLocked/.isSleeping.
        let systemObserversStore = SystemObserversStore()
        let inputMonitoringPermissionStore = InputMonitoringPermissionStore()
        let cgEventTapCollector = CGEventTapCollector(
            writer: writer,
            systemStateCollector: systemStateCollector,
            observersStore: systemObserversStore,
            permissionStore: inputMonitoringPermissionStore,
            database: database,
            minuteBucketSec: agentThresholds.cgEventTapMinuteBucketSec
        )
        let audioRouteCollector = AudioRouteCollector(writer: writer, observersStore: systemObserversStore)
        let micInUseCollector = MicInUseCollector(writer: writer, observersStore: systemObserversStore)
        let displayCollector = DisplayCollector(writer: writer, observersStore: systemObserversStore)
        let vpnCollector = VPNCollector(writer: writer, observersStore: systemObserversStore)
        let wifiCollector = WiFiCollector(
            writer: writer,
            observersStore: systemObserversStore,
            pollIntervalSec: agentThresholds.wifiPollIntervalSec
        )
        let clipboardCollector = ClipboardCollector(
            writer: writer,
            observersStore: systemObserversStore,
            pollIntervalSec: agentThresholds.clipboardPollIntervalSec
        )
        let localFilesWatcher = LocalFilesWatcher(
            writer: writer,
            observersStore: systemObserversStore,
            coalesceWindowSec: agentThresholds.localFilesCoalesceWindowSec,
            screenshotDirectoryOverride: agentThresholds.screenshotDirectoryOverridePath
        )

        AgentLifetime.writer = writer
        AgentLifetime.activeAppCollector = activeAppCollector
        AgentLifetime.idleCollector = idleCollector
        AgentLifetime.maintenance = maintenance
        AgentLifetime.claudeCodeCollector = claudeCodeCollector
        #if LEAF_PROD
        AgentLifetime.claudeCodeHookListener = hookListener
        #endif
        AgentLifetime.fsEventsCollector = fsEventsCollector
        AgentLifetime.linearCollector = linearCollector
        AgentLifetime.githubCollector = githubCollector
        AgentLifetime.slackCollector = slackCollector
        // Phase Track-3 D1 — Linear warm + cold lifetime slots.
        AgentLifetime.linearWarmCollector = linearWarmCollector
        AgentLifetime.linearWarmScheduler = linearWarmScheduler
        AgentLifetime.linearColdCollector = linearColdCollector
        AgentLifetime.linearColdScheduler = linearColdScheduler
        // Phase Track-3 D2 — GitHub scope service + warm + cold lifetime slots.
        AgentLifetime.githubScopesService = githubScopesService
        AgentLifetime.githubWarmCollector = githubWarmCollector
        AgentLifetime.githubWarmScheduler = githubWarmScheduler
        AgentLifetime.githubColdCollector = githubColdCollector
        AgentLifetime.githubColdScheduler = githubColdScheduler
        // Phase Track-3 D3 — Slack scope service + warm + cold lifetime slots.
        AgentLifetime.slackScopesService = slackScopesService
        AgentLifetime.slackWarmCollector = slackWarmCollector
        AgentLifetime.slackWarmScheduler = slackWarmScheduler
        AgentLifetime.slackColdCollector = slackColdCollector
        AgentLifetime.slackColdScheduler = slackColdScheduler
        // Phase Track-4 S1 — Architecture catch-up lifetime slots.
        AgentLifetime.calendarCollector = calendarCollector
        AgentLifetime.focusModeCollector = focusModeCollector
        AgentLifetime.systemStateCollector = systemStateCollector
        AgentLifetime.spacesCollector = spacesCollector
        // Phase Track-4 S2 — AppleScript surface.
        AgentLifetime.appleScriptCollector = appleScriptCollector
        // Phase Track-4 S3 — System observers + intensity.
        AgentLifetime.cgEventTapCollector = cgEventTapCollector
        AgentLifetime.audioRouteCollector = audioRouteCollector
        AgentLifetime.micInUseCollector = micInUseCollector
        AgentLifetime.displayCollector = displayCollector
        AgentLifetime.vpnCollector = vpnCollector
        AgentLifetime.wifiCollector = wifiCollector
        AgentLifetime.clipboardCollector = clipboardCollector
        AgentLifetime.localFilesWatcher = localFilesWatcher

        // Phase Track-6 P3 — BrowserBookmarksWatcher.
        // FSEvents-backed bookmark count watcher for Chrome (multi-profile) and
        // Safari (gated on Full Disk Access). Count probes read raw Bookmarks
        // files via BrowserBookmarkCountDeriver (LeafCorePrivate). Safari FDA
        // check is a best-effort read probe: if the plist is readable the process
        // has Full Disk Access. Emits chrome_bookmark_changed /
        // safari_bookmark_changed (delta + total_count, never URL or title strings).
        let safariBookmarksPath = NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"
        let fdaGranted = FileManager.default.isReadableFile(atPath: safariBookmarksPath)
        let browserBookmarksWatcher = BrowserBookmarksWatcher(
            writer: database,
            chromeCountProbe: { profileLabel in
                let path = NSHomeDirectory()
                    + "/Library/Application Support/Google/Chrome/"
                    + profileLabel + "/Bookmarks"
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
                #if LEAF_PROD
                return try? BrowserBookmarkCountDeriver.countChromeBookmarks(from: data)
                #else
                return nil
                #endif
            },
            safariCountProbe: { path in
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
                #if LEAF_PROD
                return try? BrowserBookmarkCountDeriver.countSafariBookmarks(from: data)
                #else
                return nil
                #endif
            },
            fdaGranted: fdaGranted
        )
        AgentLifetime.browserBookmarksWatcher = browserBookmarksWatcher

        // Phase 5.3.D — Key rotation orchestrator + RotationOutbox resume.
        // Drains unposted rotation_outbox rows from prior sessions on startup
        // (fire-and-forget). Composition root for ProdRotationKDF/ProdRotationBlobCodec
        // under #if LEAF_PROD; Unimplemented* in Debug builds. The Unimplemented
        // codec/KDF parameters are stored in KeyRotationService init but only
        // invoked from `removeMember` (UI-triggered, lives in main app); Agent's
        // `resumePendingPosts` reads encoded blobs from outbox and POSTs them
        // without touching codec/KDF, so Debug build resume works correctly.
        let rotationKDF: any RotationKDF = {
            #if LEAF_PROD
            return ProdRotationKDF()
            #else
            return UnimplementedRotationKDF()
            #endif
        }()
        let rotationBlobCodec: any RotationBlobCodec = {
            #if LEAF_PROD
            return ProdRotationBlobCodec()
            #else
            return UnimplementedRotationBlobCodec()
            #endif
        }()
        let rotationRelayClient = RelayClient()
        let keyRotationService = KeyRotationService(
            database: database,
            relayClient: rotationRelayClient,
            rotationKDF: rotationKDF,
            rotationBlobCodec: rotationBlobCodec
        )
        Task.detached {
            do {
                let outcome = try await keyRotationService.resumePendingPosts()
                if outcome.totalCount > 0 {
                    agentLogger.info("rotation resume drained: posted=\(outcome.postedCount, privacy: .public) pending=\(outcome.pendingCount, privacy: .public)")
                }
            } catch {
                agentLogger.error("rotation resume failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Phase 5.3.E — periodic peer-side rotation fetch + opportunistic outbox resume.
        // Drains relay's /v1/key-rotation/by-peer/* mailbox, peek-discriminates rotation
        // vs tombstone, installs idempotently via insertTeamKeyIfAbsent + deprecateTeamKey
        // (or markTeamMemberRemoved для self-tombstone). Mirror MaintenanceScheduler
        // actor pattern. Reuses 5.3.D rotationRelayClient/Codec/KDF instances.
        let rotationFetchService = RotationFetchService(
            database: database,
            relayClient: rotationRelayClient,
            rotationKDF: rotationKDF,
            rotationBlobCodec: rotationBlobCodec
        )
        let rotationFetchScheduler = RotationFetchScheduler(
            fetchService: rotationFetchService,
            keyRotationService: keyRotationService,
            intervalSec: agentThresholds.rotationFetchIntervalSec,
            logger: agentLogger
        )
        AgentLifetime.rotationFetchScheduler = rotationFetchScheduler

        // Phase Track-1 D3 — DetectorPipeline periodic invocation.
        // `runIncremental` runs on a periodic timer (functionally equivalent to a
        // strict per-flush hook because the cursor model is incremental + idempotent;
        // see DetectorScheduler doc comment for the architectural rationale).
        // `runScheduled` runs on a separate idle-cadence timer for LinearStuck +
        // WhereStopped aggregate scanners. Prod build wires `prodDetectorMoat()`
        // (LeafCorePrivate moat: pattern catalogues + threshold constants);
        // substrate build stays on `.publicSubstrate` so wiring is still
        // exercised in CI without shipping detection content.
        #if LEAF_PROD
        let detectorMoat: DetectorMoat = prodDetectorMoat()
        #else
        let detectorMoat: DetectorMoat = .publicSubstrate
        #endif
        let detectorScheduler = DetectorScheduler(
            database: database,
            moat: detectorMoat,
            incrementalIntervalSec: agentThresholds.detectorIncrementalIntervalSec,
            scheduledIntervalSec: agentThresholds.detectorScheduledIntervalSec,
            logger: detectorLogger
        )
        AgentLifetime.detectorScheduler = detectorScheduler

        // Kick off writer + collectors + scheduler.
        // `start()` на writer/idle — fire-and-forget Task внутри; на activeApp — запускаем
        // через DispatchQueue.main.async чтобы NSWorkspace observer'у был доступен main runloop.
        Task { await writer.start() }
        DispatchQueue.main.async { activeAppCollector.start() }
        idleCollector.start()
        Task { await maintenance.start() }
        Task { await claudeCodeCollector.start() }
        Task { await fsEventsCollector.start() }
        if let lc = linearCollector { Task { await lc.start() } }
        if let gc = githubCollector { Task { await gc.start() } }
        if let sc = slackCollector { Task { await sc.start() } }
        // Phase Track-3 D1 — start warm + cold Linear tiers (collectors first,
        // then their schedulers — symmetric with hot collector ordering).
        if let wc = linearWarmCollector { Task { await wc.start() } }
        if let ws = linearWarmScheduler { Task { await ws.start() } }
        if let cc = linearColdCollector { Task { await cc.start() } }
        if let cs = linearColdScheduler { Task { await cs.start() } }
        // Phase Track-3 D2 — start warm + cold GitHub tiers (mirror Linear D1).
        if let wc = githubWarmCollector { Task { await wc.start() } }
        if let ws = githubWarmScheduler { Task { await ws.start() } }
        if let cc = githubColdCollector { Task { await cc.start() } }
        if let cs = githubColdScheduler { Task { await cs.start() } }
        // Phase Track-3 D3 — start Slack warm + cold schedulers. Collectors
        // themselves are passive (no start()/stop() — driven entirely by
        // schedulers' tick loop, different shape from GitHub D2 / Linear D1
        // where collectors also expose start/stop).
        if let ws = slackWarmScheduler { Task { await ws.start() } }
        if let cs = slackColdScheduler { Task { await cs.start() } }
        // Phase Track-4 S1 — start Architecture catch-up collectors. Calendar
        // and Focus are async (TCC permission request + poll task); System +
        // Spaces dispatch their observer registration on main queue (callbacks
        // fire on `queue: .main`, collectors are @MainActor-isolated).
        Task { await calendarCollector.start() }
        Task { await focusModeCollector.start() }
        DispatchQueue.main.async { systemStateCollector.start() }
        DispatchQueue.main.async { spacesCollector.start() }
        // Phase Track-4 S2 — start AppleScript collector. Public substrate
        // registry is empty (start() is a no-op); Prod registry spawns one
        // polling Task per adapter.
        Task { await appleScriptCollector.start() }
        // Phase Track-4 S3 — start system observers + intensity. Each gates
        // на SystemObserversStore.isEnabled(<key>); intensity additionally
        // probes Input Monitoring TCC and silently no-ops if denied.
        Task { await cgEventTapCollector.start() }
        Task { await audioRouteCollector.start() }
        Task { await micInUseCollector.start() }
        Task { await displayCollector.start() }
        Task { await vpnCollector.start() }
        Task { await wifiCollector.start() }
        Task { await clipboardCollector.start() }
        DispatchQueue.main.async { localFilesWatcher.start() }
        // Phase Track-6 P3 — BrowserBookmarksWatcher. Sets up FSEventStreams for
        // Chrome (multi-profile) and Safari (FDA-gated) bookmark file monitoring.
        Task { await browserBookmarksWatcher.start() }
        Task { await rotationFetchScheduler.start() }
        Task { await detectorScheduler.start() }

        // Shutdown порядок: maintenance → fsEvents → claudeCode → linear → github → slack → writer.
        // fsEvents первым из collectors — закрываем приём callback'ов до того как
        // остальные collectors flush'ят. claudeCode / linear / github / slack flush'ят свои
        // текущие tick'и атомарно (events + offset в одной транзакции) — не остаётся
        // "events без offset" / "offset без events". Linear / github / slack после claudeCode
        // т.к. имеют network call в tick (медленнее на shutdown); тащить их в конец
        // chain'а minimizes overall stop latency. writer последним — drain буфера
        // attention/idle в DB перед exit.
        installSignalHandlers {
            // Phase Track-1 D3 — stop detectorScheduler first (purely read-side from
            // collectors' POV; safe to drain immediately, blocks no further writes).
            if let d = AgentLifetime.detectorScheduler { await d.stop() }
            // Phase 5.3.E — stop rotationFetchScheduler next (independent from writer
            // chain; safe to drain while collectors still emit).
            if let r = AgentLifetime.rotationFetchScheduler { await r.stop() }
            // Phase Track-3 D1 — stop Linear warm + cold tiers before maintenance.
            // Order: cold scheduler → cold collector → warm scheduler → warm collector
            // (schedulers first so they don't kick off a final tick into a stopped
            // collector).
            if let cs = AgentLifetime.linearColdScheduler { await cs.stop() }
            if let cc = AgentLifetime.linearColdCollector { await cc.stop() }
            if let ws = AgentLifetime.linearWarmScheduler { await ws.stop() }
            if let wc = AgentLifetime.linearWarmCollector { await wc.stop() }
            // Phase Track-3 D2 — stop GitHub warm + cold tiers (mirror Linear D1
            // ordering: cold scheduler → cold collector → warm scheduler → warm
            // collector). ScopesService is read-only — no stop() needed.
            if let cs = AgentLifetime.githubColdScheduler { await cs.stop() }
            if let cc = AgentLifetime.githubColdCollector { await cc.stop() }
            if let ws = AgentLifetime.githubWarmScheduler { await ws.stop() }
            if let wc = AgentLifetime.githubWarmCollector { await wc.stop() }
            // Phase Track-3 D3 — stop Slack warm + cold schedulers. Slack
            // collectors are passive (no stop()), driven entirely by the
            // schedulers' tick loop — stopping the scheduler is sufficient.
            // ScopesService is read-only — no stop() needed.
            if let cs = AgentLifetime.slackColdScheduler { await cs.stop() }
            if let ws = AgentLifetime.slackWarmScheduler { await ws.stop() }
            // Phase Track-4 S3 — stop system observers + intensity before
            // S2 AppleScript. Order: CGEventTap (heaviest, holds tap) → CoreAudio
            // listeners → display → VPN → WiFi → clipboard polling → FSEvents
            // wrapper. Reverse of start order.
            if let c = AgentLifetime.cgEventTapCollector { await c.stop() }
            if let c = AgentLifetime.audioRouteCollector { await c.stop() }
            if let c = AgentLifetime.micInUseCollector { await c.stop() }
            if let c = AgentLifetime.displayCollector { await c.stop() }
            if let c = AgentLifetime.vpnCollector { await c.stop() }
            if let c = AgentLifetime.wifiCollector { await c.stop() }
            if let c = AgentLifetime.clipboardCollector { await c.stop() }
            await MainActor.run { AgentLifetime.localFilesWatcher?.stop() }
            // Phase Track-6 P3 — stop browser bookmark watcher after localFiles.
            if let b = AgentLifetime.browserBookmarksWatcher { await b.stop() }
            // Phase Track-4 S2 — stop AppleScript collector before S1
            // collectors. Polling tasks cancel cooperatively.
            if let a = AgentLifetime.appleScriptCollector { await a.stop() }
            // Phase Track-4 S1 — stop Architecture catch-up collectors.
            // Order: spaces / system (synchronous observer removal, on main)
            // → focus / calendar (async cancel of poll task + observer).
            await MainActor.run { AgentLifetime.spacesCollector?.stop() }
            await MainActor.run { AgentLifetime.systemStateCollector?.stop() }
            if let f = AgentLifetime.focusModeCollector { await f.stop() }
            if let c = AgentLifetime.calendarCollector { await c.stop() }
            if let m = AgentLifetime.maintenance { await m.stop() }
            if let f = AgentLifetime.fsEventsCollector { await f.stop() }
            if let c = AgentLifetime.claudeCodeCollector { await c.stop() }
            // Track-6 P1 (Task 17) — close hook listener (socket FD + sources).
            #if LEAF_PROD
            AgentLifetime.claudeCodeHookListener?.stop()
            #endif
            if let l = AgentLifetime.linearCollector { await l.stop() }
            if let g = AgentLifetime.githubCollector { await g.stop() }
            if let s = AgentLifetime.slackCollector { await s.stop() }
            if let w = AgentLifetime.writer {
                await w.flush()
                await w.stop()
            }
        }

        agentLogger.info("Agent ready — entering main run loop")

        // NSWorkspace observers диспатчатся на main queue → нужен активный CFRunLoop.
        // RunLoop.main.run() блокирует forever. Shutdown через SIGTERM/SIGINT handlers.
        RunLoop.main.run()
    }
}

/// Глобальный контейнер для retain'а агентских подсистем.
/// Нужен потому что @main enum не даёт stored properties, а локалы в `main()`
/// могут быть ARC'нуты до SIGTERM handler'а.
enum AgentLifetime {
    nonisolated(unsafe) static var writer: EventWriter?
    nonisolated(unsafe) static var activeAppCollector: ActiveAppCollector?
    nonisolated(unsafe) static var idleCollector: IdleCollector?
    nonisolated(unsafe) static var maintenance: MaintenanceScheduler?
    nonisolated(unsafe) static var claudeCodeCollector: ClaudeCodeCollector?
    // Track-6 P1 (Task 17) — hook bridge listener retains the unix-domain
    // socket FD + DispatchSources for the lifetime of the agent. LEAF_PROD
    // gate matches the wiring site (listener lives in LeafCorePrivate).
    #if LEAF_PROD
    nonisolated(unsafe) static var claudeCodeHookListener: ClaudeCodeHookSocketListener?
    #endif
    nonisolated(unsafe) static var fsEventsCollector: FSEventsCollector?
    nonisolated(unsafe) static var linearCollector: LinearCollector?
    nonisolated(unsafe) static var githubCollector: GitHubCollector?
    nonisolated(unsafe) static var slackCollector: SlackCollector?
    // Phase 5.3.E — peer-side rotation fetch loop.
    nonisolated(unsafe) static var rotationFetchScheduler: RotationFetchScheduler?
    // Phase Track-1 D3 — periodic detector pipeline (incremental + scheduled passes).
    nonisolated(unsafe) static var detectorScheduler: DetectorScheduler?
    // Phase Track-3 D1 — Linear warm/cold collectors + their schedulers.
    nonisolated(unsafe) static var linearWarmCollector: LinearWarmCollector?
    nonisolated(unsafe) static var linearWarmScheduler: LinearWarmScheduler?
    nonisolated(unsafe) static var linearColdCollector: LinearColdCollector?
    nonisolated(unsafe) static var linearColdScheduler: LinearColdScheduler?
    // Phase Track-3 D2 — GitHub scope service + warm/cold collectors + their
    // schedulers. ScopesService is shared between warm + cold and exposed for
    // UI/observer consumers (Tasks 16/21).
    nonisolated(unsafe) static var githubScopesService: GitHubScopesService?
    nonisolated(unsafe) static var githubWarmCollector: GitHubWarmCollector?
    nonisolated(unsafe) static var githubWarmScheduler: GitHubWarmScheduler?
    nonisolated(unsafe) static var githubColdCollector: GitHubColdCollector?
    nonisolated(unsafe) static var githubColdScheduler: GitHubColdScheduler?
    // Phase Track-3 D3 — Slack scope service + warm/cold collectors + their
    // schedulers. ScopesService is shared between warm + cold and exposed for
    // UI/observer consumers (mirror GitHub D2 precedent).
    nonisolated(unsafe) static var slackScopesService: SlackScopesService?
    nonisolated(unsafe) static var slackWarmCollector: SlackWarmCollector?
    nonisolated(unsafe) static var slackWarmScheduler: SlackWarmScheduler?
    nonisolated(unsafe) static var slackColdCollector: SlackColdCollector?
    nonisolated(unsafe) static var slackColdScheduler: SlackColdScheduler?
    // Phase Track-4 S1 — Architecture catch-up collectors (Layer A).
    nonisolated(unsafe) static var calendarCollector: CalendarCollector?
    nonisolated(unsafe) static var focusModeCollector: FocusModeCollector?
    nonisolated(unsafe) static var systemStateCollector: SystemStateCollector?
    nonisolated(unsafe) static var spacesCollector: SpacesCollector?
    // Phase Track-4 S2 — AppleScript surface orchestrator.
    nonisolated(unsafe) static var appleScriptCollector: AppleScriptCollector?
    // Phase Track-4 S3 — System observers + intensity.
    nonisolated(unsafe) static var cgEventTapCollector: CGEventTapCollector?
    nonisolated(unsafe) static var audioRouteCollector: AudioRouteCollector?
    nonisolated(unsafe) static var micInUseCollector: MicInUseCollector?
    nonisolated(unsafe) static var displayCollector: DisplayCollector?
    nonisolated(unsafe) static var vpnCollector: VPNCollector?
    nonisolated(unsafe) static var wifiCollector: WiFiCollector?
    nonisolated(unsafe) static var clipboardCollector: ClipboardCollector?
    nonisolated(unsafe) static var localFilesWatcher: LocalFilesWatcher?
    // Phase Track-6 P3 — browser bookmark FSEvents watcher.
    nonisolated(unsafe) static var browserBookmarksWatcher: BrowserBookmarksWatcher?
}
