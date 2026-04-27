//
//  LeafApp.swift
//  Leaf
//

import SwiftUI
import os
import LeafCore
#if LEAF_PROD
import LeafCorePrivate
#endif

private let leafAppLogger = Logger(subsystem: "tech.gundem.leaf", category: "app")

@main
struct LeafApp: App {
    @State private var launchAgent: LaunchAgentService
    @State private var watchedFolders = WatchedFoldersService()
    @State private var permissions = PermissionsService()
    @State private var updater: UpdaterController

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
        MenuBarExtra("Leaf", systemImage: "leaf") {
            MenuBarContent()
                .environment(launchAgent)
                .environment(watchedFolders)
                .environment(permissions)
                .environment(updater)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(launchAgent)
                .environment(watchedFolders)
                .environment(permissions)
                .environment(updater)
        }
    }
}
