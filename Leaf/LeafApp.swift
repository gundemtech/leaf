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
    @NSApplicationDelegateAdaptor(LeafAppDelegate.self) private var appDelegate
    @State private var launchAgent: LaunchAgentService
    @State private var watchedFolders = WatchedFoldersService()
    @State private var linearOAuth = LinearOAuthService()
    @State private var githubOAuth = GitHubOAuthService()
    @State private var slackOAuth = SlackOAuthService()
    @State private var permissions = PermissionsService()
    @State private var updater: UpdaterController
    @State private var reader = InsightsReader()
    @State private var orgReader = OrgReader()
    @State private var inviteOutboxReader = InviteOutboxReader()
    @State private var inviteAcceptReader = InviteAcceptReader()
    @State private var windowState = WindowState()

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
        Window("Leaf", id: "main") {
            RootView()
                .environment(launchAgent)
                .environment(watchedFolders)
                .environment(linearOAuth)
                .environment(githubOAuth)
                .environment(slackOAuth)
                .environment(permissions)
                .environment(updater)
                .environment(reader)
                .environment(orgReader)
                .environment(inviteOutboxReader)
                .environment(inviteAcceptReader)
                .environment(windowState)
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                OpenSettingsCommand(windowState: windowState)
            }
        }

        MenuBarExtra("Leaf", systemImage: "leaf") {
            MenuBarContent()
                .environment(launchAgent)
                .environment(watchedFolders)
                .environment(permissions)
                .environment(updater)
                .environment(reader)
                .environment(windowState)
        }
        .menuBarExtraStyle(.window)
    }
}

/// `applicationShouldHandleReopen` нужен чтобы клик по Dock-иконке (после
/// того как юзер закрыл окно) снова открывал главное окно. Без этого SwiftUI
/// `Window` не реагирует на reopen — менюбар-присутствие "съедает" событие.
final class LeafAppDelegate: NSObject, NSApplicationDelegate {
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
