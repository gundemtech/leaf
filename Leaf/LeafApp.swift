//
//  LeafApp.swift
//  Leaf
//

import SwiftUI
import UserNotifications
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
    // Track 5 S2 Task 12 — `OrgReader` deleted. `WorkspaceReader` +
    // `ActiveWorkspaceStore` — sole substrate for workspace surface.
    @State private var activeWorkspaceStore: ActiveWorkspaceStore
    @State private var workspaceReader: WorkspaceReader
    /// Track 5 / S3 — Leaf's first network primitive. Constructed once at LeafApp.init
    /// time and injected into all invite readers + future S4+ readers.
    @State private var supabaseClient: SupabaseClient
    @State private var inviteOutboxReader: InviteOutboxReader
    @State private var inviteAcceptReader: InviteAcceptReader
    /// Track 5 / S4 — DM send + inbox + APNs registration readers.
    @State private var directMessageSendReader: DirectMessageSendReader
    @State private var directMessageInboxReader: DirectMessageInboxReader
    @State private var apnsRegistrationReader: APNsRegistrationReader
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

        // Track 5 / S3 — SupabaseClient is the first Mac client primitive talking to Supabase.
        // baseURL + anonKey read from Info.plist (xcconfig substitution).
        // Track 5 / S4 — adds SupabaseSessionStore for refresh_token persistence (closes I3).
        let supabaseSessionStore = SupabaseSessionStore(at: TeamKeystore.defaultRoot())
        let supabase = SupabaseClient(
            baseURL: SupabaseConfig.baseURL(from: Bundle.main),
            anonKey: SupabaseConfig.anonKey(from: Bundle.main),
            identity: { try IdentityService.ensureLocalIdentity(at: TeamKeystore.defaultRoot()) },
            sessionStore: supabaseSessionStore
        )
        _supabaseClient = State(initialValue: supabase)
        _inviteOutboxReader = State(initialValue: InviteOutboxReader(supabase: supabase))
        _inviteAcceptReader = State(initialValue: InviteAcceptReader(supabase: supabase))

        // Track 5 / S4 — direct-messages substrate readers.
        let sendReader = DirectMessageSendReader(supabase: supabase, activeWorkspaceStore: active)
        let inboxReader = DirectMessageInboxReader(supabase: supabase, activeWorkspaceStore: active)
        let apnsReader = APNsRegistrationReader(supabase: supabase)
        _directMessageSendReader = State(initialValue: sendReader)
        _directMessageInboxReader = State(initialValue: inboxReader)
        _apnsRegistrationReader = State(initialValue: apnsReader)

        // C1 fix — Track 5 / S4 Stage 6 review:
        // AppDelegate handles APNs callbacks and needs reader references. SwiftUI
        // doesn't propagate @Environment into AppDelegate callbacks; static weak
        // refs bridge that gap. Populated here before any APNs registration fires.
        LeafAppDelegate.directMessageInboxReader = inboxReader
        LeafAppDelegate.apnsRegistrationReader = apnsReader

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
                .environment(workspaceReader)            // Track 5 S2 Task 10
                .environment(activeWorkspaceStore)       // Track 5 S2 Task 10
                // Track 5 / S3 — SupabaseClient is an actor (not @Observable), injected directly
                // into readers via constructor. UI surfaces consume readers, not the client directly.
                .environment(inviteOutboxReader)
                .environment(inviteAcceptReader)
                .environment(directMessageSendReader)   // Track 5 / S4
                .environment(directMessageInboxReader)  // Track 5 / S4
                .environment(apnsRegistrationReader)    // Track 5 / S4
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
///
/// Track 5 / S4 — Stage 6 review C1 fix: APNs callbacks added.
/// AppDelegate keeps weak refs to readers via MainActor-isolated static
/// accessors that LeafApp.init populates. SwiftUI doesn't propagate
/// `@Environment` into AppDelegate callbacks, so static handoff is the
/// pragmatic bridge.
final class LeafAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    @MainActor static weak var apnsRegistrationReader: APNsRegistrationReader?
    @MainActor static weak var directMessageInboxReader: DirectMessageInboxReader?

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Track 5 / S4 — APNs registration. Requires aps-environment entitlement
        // (added separately for signed builds). In dev / unsigned builds, the
        // registration request silently no-ops on macOS.
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                NSApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func application(_ application: NSApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        let env: String
        #if DEBUG
        env = "development"
        #else
        env = "production"
        #endif
        Task { @MainActor in
            await Self.apnsRegistrationReader?.recordToken(tokenHex, environment: env)
        }
    }

    func application(_ application: NSApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        leafAppLogger.error("APNs register failed: \(String(describing: error), privacy: .public)")
    }

    func application(_ application: NSApplication,
                     didReceiveRemoteNotification userInfo: [String: Any]) {
        // Spec §10.3 payload: leaf_message_id + leaf_workspace_id.
        guard let messageID = userInfo["leaf_message_id"] as? String,
              let workspaceID = userInfo["leaf_workspace_id"] as? String else {
            return
        }
        Task { @MainActor in
            await Self.directMessageInboxReader?.tickOnce(
                workspaceID: workspaceID, forMessageID: messageID
            )
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show banner / sound when notification arrives while app is foregrounded.
    /// Without this delegate method, macOS silently drops foreground notifications.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        return [.banner, .sound, .badge]
    }

    /// User clicked notification → eager-fetch the referenced message.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        guard let messageID = userInfo["leaf_message_id"] as? String,
              let workspaceID = userInfo["leaf_workspace_id"] as? String else {
            return
        }
        await Self.directMessageInboxReader?.tickOnce(
            workspaceID: workspaceID, forMessageID: messageID
        )
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
