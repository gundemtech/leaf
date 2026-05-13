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
    @State private var orgReader = OrgReader()
    // Track 5 S2 Task 10 — parallel multi-workspace substrate. `OrgReader` остаётся
    // в @State до Task 12 (delete), оба reader'а живут side-by-side. Views мигрируют
    // на `WorkspaceReader`; `ActiveWorkspaceStore` инжектится для прямого чтения
    // active-workspace id (Sidebar switcher и т.п.).
    @State private var activeWorkspaceStore: ActiveWorkspaceStore
    @State private var workspaceReader: WorkspaceReader
    @State private var inviteOutboxReader = InviteOutboxReader()
    @State private var inviteAcceptReader = InviteAcceptReader()
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
                .environment(orgReader)
                .environment(workspaceReader)            // Track 5 S2 Task 10
                .environment(activeWorkspaceStore)       // Track 5 S2 Task 10
                .environment(inviteOutboxReader)
                .environment(inviteAcceptReader)
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
                .environment(orgReader)
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
