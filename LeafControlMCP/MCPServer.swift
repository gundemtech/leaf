import Foundation
import LeafControlCore
import LeafControlMCPProtocol

#if LEAFCONTROL_PROD
import LeafControlCorePrivate
#endif

@main
enum MCPMain {
    static func main() async {
        #if LEAFCONTROL_PROD
        let dbConfig = ProdConfigs.database
        DerivedInsightsFactory.register { LeafControlCorePrivate.ProdInsights(database: $0) }
        let prodMode = true
        #else
        let dbConfig = DatabaseConfig.weakDefaults
        let prodMode = false
        #endif

        MCPLog.info("leafcontrol-mcp v\(MCPConstants.serverVersion) starting (prod=\(prodMode))")

        let dbURL = DatabasePath.defaultURL()
        let timelineTool = GetTimelineTool(dbURL: dbURL, dbConfig: dbConfig)

        // Notifications (`notifications/*`) обрабатываются Dispatcher'ом через
        // id == nil short-circuit — отдельный handler регистрировать не нужно.
        let dispatcher = Dispatcher(handlers: [
            "initialize": InitializeHandler(),
            "tools/list": ToolsListHandler(tools: [GetTimelineTool.definition]),
            "tools/call": ToolsCallHandler(registry: ["get_timeline": timelineTool])
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
