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
        let dbEncryption: EncryptionOptions? = {
            let accessGroup = KeychainAccessGroup.current()
            return EncryptionOptions(
                keyProvider: .callback { @Sendable in
                    try KeychainKeyStore.fetchOrCreate(accessGroup: accessGroup)
                },
                preKeyPragmas: ProdConfigs.sqlcipherPragmasPreKey,
                postKeyPragmas: ProdConfigs.sqlcipherPragmasPostKey
            )
        }()
        let focusSessionGapSec: TimeInterval = ProdConfigs.agent.focusSessionGapSec
        #else
        let dbConfig = DatabaseConfig.weakDefaults
        let prodMode = false
        let dbEncryption: EncryptionOptions? = nil
        let focusSessionGapSec: TimeInterval = AgentThresholds.weakDefaults.focusSessionGapSec
        #endif

        MCPLog.info("leaf-mcp v\(MCPConstants.serverVersion) starting (prod=\(prodMode))")

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

        // Notifications (`notifications/*`) обрабатываются Dispatcher'ом через
        // id == nil short-circuit — отдельный handler регистрировать не нужно.
        let dispatcher = Dispatcher(handlers: [
            "initialize": InitializeHandler(),
            "tools/list": ToolsListHandler(tools: [
                GetTimelineTool.definition,
                FindLastActivityTool.definition,
                GetCurrentSessionTool.definition,
                GetAiActivityTool.definition
            ]),
            "tools/call": ToolsCallHandler(registry: [
                "get_timeline": timelineTool,
                "find_last_activity": findLastActivityTool,
                "get_current_session": currentSessionTool,
                "get_ai_activity": aiActivityTool
            ])
        ])

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
}
