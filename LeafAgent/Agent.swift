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

        AgentLifetime.writer = writer
        AgentLifetime.activeAppCollector = activeAppCollector
        AgentLifetime.idleCollector = idleCollector
        AgentLifetime.maintenance = maintenance
        AgentLifetime.claudeCodeCollector = claudeCodeCollector
        AgentLifetime.fsEventsCollector = fsEventsCollector
        AgentLifetime.linearCollector = linearCollector
        AgentLifetime.githubCollector = githubCollector
        AgentLifetime.slackCollector = slackCollector

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
            if let m = AgentLifetime.maintenance { await m.stop() }
            if let f = AgentLifetime.fsEventsCollector { await f.stop() }
            if let c = AgentLifetime.claudeCodeCollector { await c.stop() }
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
    nonisolated(unsafe) static var fsEventsCollector: FSEventsCollector?
    nonisolated(unsafe) static var linearCollector: LinearCollector?
    nonisolated(unsafe) static var githubCollector: GitHubCollector?
    nonisolated(unsafe) static var slackCollector: SlackCollector?
    // Phase 5.3.E — peer-side rotation fetch loop.
    nonisolated(unsafe) static var rotationFetchScheduler: RotationFetchScheduler?
    // Phase Track-1 D3 — periodic detector pipeline (incremental + scheduled passes).
    nonisolated(unsafe) static var detectorScheduler: DetectorScheduler?
}
