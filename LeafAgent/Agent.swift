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
        let databaseEncryption: EncryptionOptions? = {
            let accessGroup = KeychainAccessGroup.current()
            return EncryptionOptions(
                keyProvider: .callback { @Sendable in
                    try KeychainKeyStore.fetchOrCreate(accessGroup: accessGroup)
                },
                preKeyPragmas: ProdConfigs.sqlcipherPragmasPreKey,
                postKeyPragmas: ProdConfigs.sqlcipherPragmasPostKey
            )
        }()
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
        let activeAppCollector = ActiveAppCollector(writer: writer, blocklist: Blocklist.phase1Default)
        let idleCollector = IdleCollector(writer: writer, thresholds: agentThresholds)
        let maintenance = MaintenanceScheduler(
            database: database,
            walCheckpointIntervalSec: databaseConfig.walCheckpointIntervalSec,
            retentionSweepIntervalSec: agentThresholds.retentionSweepIntervalSec,
            retentionDays: agentThresholds.retentionDays,
            logger: maintenanceLogger
        )

        AgentLifetime.writer = writer
        AgentLifetime.activeAppCollector = activeAppCollector
        AgentLifetime.idleCollector = idleCollector
        AgentLifetime.maintenance = maintenance

        // Kick off writer + collectors + scheduler.
        // `start()` на writer/idle — fire-and-forget Task внутри; на activeApp — запускаем
        // через DispatchQueue.main.async чтобы NSWorkspace observer'у был доступен main runloop.
        Task { await writer.start() }
        DispatchQueue.main.async { activeAppCollector.start() }
        idleCollector.start()
        Task { await maintenance.start() }

        // Shutdown порядок: maintenance → writer (flush + stop) → exit.
        // maintenance первым — новый sweep/checkpoint не стартанёт.
        // writer вторым — финальный drain буфера в DB.
        installSignalHandlers {
            if let m = AgentLifetime.maintenance { await m.stop() }
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
}
