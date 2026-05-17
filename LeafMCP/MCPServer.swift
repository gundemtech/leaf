import Foundation
import LeafCore
import LeafMCPProtocol

#if LEAF_PROD
import LeafCorePrivate
#endif

@main
enum MCPMain {

    private struct RuntimeConfig {
        let dbConfig: DatabaseConfig
        let dbEncryption: EncryptionOptions?
        let focusSessionGapSec: TimeInterval
        let prodMode: Bool
        let detectorMoat: DetectorMoat
    }

    static func main() async {
        let cfg = resolveRuntimeConfig()
        MCPLog.info("leaf-mcp v\(MCPConstants.serverVersion) starting (prod=\(cfg.prodMode))")

        let dispatcher = buildDispatcher(cfg: cfg, dbURL: DatabasePath.defaultURL())
        let transport = StdioTransport(dispatcher: dispatcher)

        // Shutdown: Claude Code закрывает stdin перед SIGTERM (см. MCP spec
        // lifecycle). В async main() без RunLoop.main.run() DispatchSource
        // signal handlers на .main queue ненадёжны (cooperative concurrency
        // runtime vs explicit runloop pumping) → полагаемся на stdin EOF для
        // graceful shutdown и default SIGTERM action для forced kill.
        do {
            try await transport.serve()
            MCPLog.info("transport returned normally — exit(0)")
            exit(0)
        } catch {
            MCPLog.error("transport failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    /// Resolve prod vs substrate runtime config. Prod build registers
    /// `ProdInsights` factory + wires file-keystore encryption + Phase
    /// Track-1 D3 prodDetectorMoat (pattern catalogues + thresholds +
    /// Levenshtein fuzz match). Substrate build keeps `.publicSubstrate`
    /// no-op detectors — `leaf_query_activity` still works via FTS+links,
    /// `leaf_get_decision` / `leaf_current_work` gracefully return empty.
    private static func resolveRuntimeConfig() -> RuntimeConfig {
        #if LEAF_PROD
        DerivedInsightsFactory.register { LeafCorePrivate.ProdInsights(database: $0) }
        return RuntimeConfig(
            dbConfig: ProdConfigs.database,
            dbEncryption: EncryptionOptions(
                keyProvider: .callback { @Sendable in
                    try FileKeyStore.fetchOrCreate()
                },
                preKeyPragmas: ProdConfigs.sqlcipherPragmasPreKey,
                postKeyPragmas: ProdConfigs.sqlcipherPragmasPostKey
            ),
            focusSessionGapSec: ProdConfigs.agent.focusSessionGapSec,
            prodMode: true,
            detectorMoat: prodDetectorMoat()
        )
        #else
        return RuntimeConfig(
            dbConfig: DatabaseConfig.weakDefaults,
            dbEncryption: nil,
            focusSessionGapSec: AgentThresholds.weakDefaults.focusSessionGapSec,
            prodMode: false,
            detectorMoat: .publicSubstrate
        )
        #endif
    }

    /// Build the full 15-tool dispatcher. Notifications (`notifications/*`)
    /// обрабатываются Dispatcher'ом через id == nil short-circuit — отдельный
    /// handler регистрировать не нужно.
    private static func buildDispatcher(cfg: RuntimeConfig, dbURL: URL) -> Dispatcher {
        let dbConfig = cfg.dbConfig
        let dbEncryption = cfg.dbEncryption
        let detectorMoat = cfg.detectorMoat

        let timelineTool = GetTimelineTool(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
        let findLastActivityTool = FindLastActivityTool(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
        let currentSessionTool = GetCurrentSessionTool(
            dbURL: dbURL,
            dbConfig: dbConfig,
            dbEncryption: dbEncryption,
            focusSessionGapSec: cfg.focusSessionGapSec
        )
        let aiActivityTool = GetAiActivityTool(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
        let linearActivityTool = GetLinearActivityTool(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
        let githubActivityTool = GetGitHubActivityTool(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
        let slackActivityTool = GetSlackActivityTool(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
        let uninterruptedWindowTool = GetUninterruptedWindowTool(
            dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
        let currentPresenceTool = GetCurrentPresenceTool(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
        let workloadPulseTool = GetWorkloadPulseTool(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
        let reviewActivityTool = GetReviewActivityTool(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
        let crossProviderThreadTool = GetCrossProviderThreadTool(
            dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
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

        return Dispatcher(handlers: [
            "initialize": InitializeHandler(),
            "tools/list": ToolsListHandler(tools: [
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
            ]),
            "tools/call": ToolsCallHandler(registry: [
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
            ]),
        ])
    }
}
