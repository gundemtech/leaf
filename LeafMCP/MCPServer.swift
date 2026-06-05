import CryptoKit
import Foundation
import LeafCore
import LeafMCPProtocol

#if LEAF_PROD
import LeafCorePrivate
#endif

@main
enum MCPMain {
    static func main() async {
        #if LEAF_PROD
        let dbConfig = ProdConfigs.database
        DerivedInsightsFactory.register { LeafCorePrivate.ProdInsights(database: $0) }
        let prodMode = true
        let dbEncryption: EncryptionOptions? = EncryptionOptions(
            keyProvider: .callback { @Sendable in
                try FileKeyStore.fetchOrCreate()
            },
            preKeyPragmas: ProdConfigs.sqlcipherPragmasPreKey,
            postKeyPragmas: ProdConfigs.sqlcipherPragmasPostKey
        )
        let focusSessionGapSec: TimeInterval = ProdConfigs.agent.focusSessionGapSec
        #else
        let dbConfig = DatabaseConfig.weakDefaults
        let prodMode = false
        let dbEncryption: EncryptionOptions? = nil
        let focusSessionGapSec: TimeInterval = AgentThresholds.weakDefaults.focusSessionGapSec
        #endif

        MCPLog.info("leaf-mcp v\(MCPConstants.serverVersion) starting (prod=\(prodMode))")

        // Phase Track-1 D3 — DetectorMoat injection point. Prod build wires
        // `prodDetectorMoat()` (LeafCorePrivate moat: pattern catalogues +
        // threshold constants + Levenshtein fuzz match). Substrate build keeps
        // `.publicSubstrate` (no-op detectors — `leaf_query_activity` still
        // works via FTS+links, `leaf_get_decision` / `leaf_current_work`
        // gracefully return empty results).
        #if LEAF_PROD
        let detectorMoat: DetectorMoat = prodDetectorMoat()
        #else
        let detectorMoat: DetectorMoat = .publicSubstrate
        #endif

        // Track AI Coworker P1 — Default Q&A (`ask_about_my_work`). Prod wires the
        // BYOK summarizer (key read from the file-based store — MCPServer can't
        // reach the app Keychain), the model gate, and the LLM egress moat
        // (bucket-1 personal-app list). Substrate keeps NoOp/empty → the tool
        // returns a graceful "no API key" error. The AI-included (proxy) path is
        // built/tested but NOT wired here (it needs the app's Supabase session).
        #if LEAF_PROD
        let aiSummarizerMoat: AISummarizerMoat = prodAISummarizerMoat(keyStore: FileAnthropicKeyStore())
        let modelGateMoat: ModelGateMoat = prodModelGateMoat()
        let llmEgressMoat: LLMEgressMoat = prodLLMEgressMoat()
        #else
        let aiSummarizerMoat: AISummarizerMoat = .publicSubstrate
        let modelGateMoat: ModelGateMoat = .publicSubstrate
        let llmEgressMoat: LLMEgressMoat = .publicSubstrate
        #endif
        let llmPolicy = LLMPolicy(
            moat: llmEgressMoat,
            config: LLMPolicyConfig(strictMode: StrictModeReader.read()))

        let dbURL = DatabasePath.defaultURL()
        let timelineTool = GetTimelineTool(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
        let findLastActivityTool = FindLastActivityTool(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
        let currentSessionTool = GetCurrentSessionTool(
            dbURL: dbURL,
            dbConfig: dbConfig,
            dbEncryption: dbEncryption,
            focusSessionGapSec: focusSessionGapSec
        )
        let aiActivityTool = GetAiActivityTool(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
        let linearActivityTool = GetLinearActivityTool(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
        let githubActivityTool = GetGitHubActivityTool(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
        let slackActivityTool = GetSlackActivityTool(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
        let uninterruptedWindowTool = GetUninterruptedWindowTool(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
        let currentPresenceTool = GetCurrentPresenceTool(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
        let workloadPulseTool = GetWorkloadPulseTool(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
        let reviewActivityTool = GetReviewActivityTool(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
        let crossProviderThreadTool = GetCrossProviderThreadTool(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
        let queryActivityTool = QueryActivityTool(
            dbURL: dbURL, dbConfig: dbConfig,
            dbEncryption: dbEncryption, detectorMoat: detectorMoat
        )
        let getDecisionTool = GetDecisionTool(
            dbURL: dbURL, dbConfig: dbConfig,
            dbEncryption: dbEncryption, detectorMoat: detectorMoat
        )
        let currentWorkTool = CurrentWorkTool(
            dbURL: dbURL, dbConfig: dbConfig,
            dbEncryption: dbEncryption, detectorMoat: detectorMoat
        )
        let askAboutMyWorkTool = AskAboutMyWorkTool(
            dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption,
            policy: llmPolicy, summarizerMoat: aiSummarizerMoat, modelGateMoat: modelGateMoat
        )
        // Track AI Coworker P3 — escalation (bodies-on-demand) + the read-back log.
        // `escalate_to_ai` opens a brief writer for the audit append (ADR-019
        // departure — see EscalateToAITool); `get_ai_escalation_log` is read-only.
        let escalateToAITool = EscalateToAITool(
            dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption,
            policy: llmPolicy, summarizerMoat: aiSummarizerMoat, modelGateMoat: modelGateMoat
        )
        let aiEscalationLogTool = GetAIEscalationLogTool(
            dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption
        )

        // Track 5 / S8 / T7 — `leaf_query_team` tool. Constructs a
        // reader-mode Database handle (MCPServer is a read-only process per
        // ADR-019 — only the Agent writes to events.sqlite) plus the two
        // provider closures the service needs: active workspace id from the
        // UserDefaults key that the main app's `ActiveWorkspaceStore`
        // persists (`ActiveWorkspaceStore.userDefaultsKey`), and self
        // pubkey hex from the on-disk X25519 identity key (read via
        // `IdentityService.ensureLocalIdentity` — idempotent: if the file
        // exists this is a pure read).
        let queryTeamTool: QueryTeamTool? = {
            guard FileManager.default.fileExists(atPath: dbURL.path) else {
                MCPLog.info("leaf_query_team: events.sqlite missing — tool not registered")
                return nil
            }
            do {
                let queryDB = try Database.openForRead(
                    at: dbURL, config: dbConfig, encryption: dbEncryption
                )
                let activeWorkspaceProvider: TeamTimelineQueryService.ActiveWorkspaceProvider = {
                    UserDefaults.standard.string(forKey: ActiveWorkspaceStore.userDefaultsKey)
                }
                let selfPubkeyProvider: TeamTimelineQueryService.SelfPubkeyProvider = {
                    do {
                        let priv = try IdentityService.ensureLocalIdentity()
                        return priv.publicKey.rawRepresentation
                            .map { String(format: "%02x", $0) }
                            .joined()
                    } catch {
                        return nil
                    }
                }
                let service = TeamTimelineQueryService(
                    database: queryDB,
                    activeWorkspaceProvider: activeWorkspaceProvider,
                    selfPubkeyProvider: selfPubkeyProvider
                )
                return QueryTeamTool(queryService: service)
            } catch {
                MCPLog.error("leaf_query_team init failed: \(error.localizedDescription)")
                return nil
            }
        }()

        // Notifications (`notifications/*`) are handled by the Dispatcher via
        // the id == nil short-circuit — no separate handler needs to be registered.
        // Track 5 / S8 / T7 — tools list + registry conditionally include
        // `leaf_query_team` only when the Database open above succeeded.
        // Without a DB handle the tool cannot serve any query; surfacing its
        // schema in `tools/list` but failing every call is worse UX than
        // omitting it (AI client will not advertise a feature that always
        // errors). MCP tool count: 18 base (+P3 escalate_to_ai +
        // get_ai_escalation_log) + 1 (S8/T7) = 19 when active.
        var toolDefinitions: [ToolDefinition] = [
            GetTimelineTool.definition,
            FindLastActivityTool.definition,
            GetCurrentSessionTool.definition,
            GetAiActivityTool.definition,
            GetLinearActivityTool.definition,
            GetGitHubActivityTool.definition,
            GetSlackActivityTool.definition,
            GetUninterruptedWindowTool.definition,
            GetCurrentPresenceTool.definition,
            GetWorkloadPulseTool.definition,
            GetReviewActivityTool.definition,
            GetCrossProviderThreadTool.definition,
            QueryActivityTool.definition,
            GetDecisionTool.definition,
            CurrentWorkTool.definition,
            AskAboutMyWorkTool.definition,
            EscalateToAITool.definition,
            GetAIEscalationLogTool.definition
        ]
        var toolRegistry: [String: any ToolExecutor] = [
            "get_timeline": timelineTool,
            "find_last_activity": findLastActivityTool,
            "get_current_session": currentSessionTool,
            "get_ai_activity": aiActivityTool,
            "get_linear_activity": linearActivityTool,
            "get_github_activity": githubActivityTool,
            "get_slack_activity": slackActivityTool,
            "get_uninterrupted_window": uninterruptedWindowTool,
            "get_current_presence": currentPresenceTool,
            "get_workload_pulse": workloadPulseTool,
            "get_review_activity": reviewActivityTool,
            "get_cross_provider_thread": crossProviderThreadTool,
            "leaf_query_activity": queryActivityTool,
            "leaf_get_decision": getDecisionTool,
            "leaf_current_work": currentWorkTool,
            "ask_about_my_work": askAboutMyWorkTool,
            "escalate_to_ai": escalateToAITool,
            "get_ai_escalation_log": aiEscalationLogTool
        ]
        if let qtt = queryTeamTool {
            toolDefinitions.append(QueryTeamTool.definition)
            toolRegistry["leaf_query_team"] = qtt
        }

        let dispatcher = Dispatcher(handlers: [
            "initialize": InitializeHandler(),
            "tools/list": ToolsListHandler(tools: toolDefinitions),
            "tools/call": ToolsCallHandler(registry: toolRegistry)
        ])

        let transport = StdioTransport(dispatcher: dispatcher)

        // Shutdown: Claude Code closes stdin before SIGTERM (see MCP spec
        // lifecycle). In async main() without RunLoop.main.run(), DispatchSource
        // signal handlers on the .main queue are unreliable (cooperative concurrency
        // runtime vs explicit runloop pumping) → we rely on stdin EOF for
        // graceful shutdown and the default SIGTERM action for forced kill.
        do {
            try await transport.serve()
            MCPLog.info("transport returned normally — exit(0)")
            exit(0)
        } catch {
            MCPLog.error("transport failed: \(error.localizedDescription)")
            exit(1)
        }
    }
}
