//
//  NotificationPrefsReader.swift
//  Leaf
//
//  Track 5 / S8 / T9 — @Observable wrapper around `NotificationPrefsStore` (T1
//  substrate) for `NotificationsSettingsSection` toggle binding.
//
//  Per ShareRulesReader precedent (S5): opens its own `LeafCore.Database`
//  handle (writer mode — `setEnabled` needs to UPSERT). NotificationPrefs are
//  device-wide (no `workspace_id` column on `notification_prefs` per spec §6),
//  so unlike ShareRulesReader there's no `ActiveWorkspaceStore` dependency.
//
//  `setEnabled` persists the local row first (source of truth), then
//  best-effort mirrors to Supabase via `SupabaseClient.upsertNotificationPref`
//  — the server row is a hint for `apns_push` Edge Function to skip pushes
//  for disabled kinds (T5). Server mirror failure is swallowed (`try?`); local
//  persistence success is what the UI binds to.
//
//  Locked-kind UX (only `.handoff` currently): UI renders the toggle as
//  disabled + shows a lock icon next to the label; `setEnabled(.handoff,
//  enabled: false)` shouldn't fire in normal flow. Defence-in-depth: if it
//  does fire, the store throws `cannotDisableLockedKind` and we silently
//  re-read the effective map (toggle snaps back to ON).
//

import Foundation
import Observation
import OSLog
import SwiftUI
import LeafCore
#if LEAF_PROD
import LeafCorePrivate
#endif

@MainActor
@Observable
final class NotificationPrefsReader {

    /// Materialized effective map (all 11 `NotificationKind` cases populated).
    /// Reads default ON/OFF from `NotificationKind.defaultEnabled` when no row
    /// persisted. Refreshed after every successful local write.
    private(set) var effective: [NotificationKind: Bool] = NotificationPrefsReader.seedDefaults()

    private var database: LeafCore.Database?
    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let supabaseClient: SupabaseClient?
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "notification-prefs")

    init(
        supabaseClient: SupabaseClient? = nil,
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = NotificationPrefsReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = NotificationPrefsReader.defaultEncryption()
    ) {
        self.supabaseClient = supabaseClient
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
    }

    /// Initializer for tests that supply a pre-opened database (in-memory or
    /// temporary path). Bypasses the lazy `ensureDatabase()` path.
    init(database: LeafCore.Database, supabaseClient: SupabaseClient? = nil) {
        self.database = database
        self.databaseURL = URL(fileURLWithPath: "/dev/null")
        self.databaseConfig = DatabaseConfig.weakDefaults
        self.databaseEncryption = nil
        self.supabaseClient = supabaseClient
    }

    /// Read effective map. Idempotent. Falls back to defaults on DB-open
    /// failure so the UI never crashes; logger records the issue.
    func refresh() {
        do {
            let db = try ensureDatabase()
            let map = try db.readNotificationPrefs()
            effective = map
        } catch {
            logger.error("NotificationPrefsReader.refresh: \(String(describing: error), privacy: .public)")
            // Fall back to defaults — UI still renders toggles with correct
            // ON/OFF state per `NotificationKind.defaultEnabled`.
            effective = NotificationPrefsReader.seedDefaults()
        }
    }

    /// Resolves single-kind effective state via the in-memory map. Falls back
    /// to `kind.defaultEnabled` if `refresh()` hasn't populated yet.
    func isEnabled(_ kind: NotificationKind) -> Bool {
        effective[kind] ?? kind.defaultEnabled
    }

    /// User-facing toggle handler. Persists local UPSERT immediately;
    /// best-effort server mirror via `SupabaseClient.upsertNotificationPref`
    /// (failure swallowed — `apns_push` Edge Function reads server row as
    /// hint; local stays source of truth).
    ///
    /// Locked-kind safeguard: `setEnabled(.handoff, enabled: false)` throws
    /// `cannotDisableLockedKind` from the store; we silently re-read the map
    /// (toggle snaps back to ON) and log. UI prevents this from firing via
    /// `.disabled(kind.locked)` on the Toggle.
    func setEnabled(_ kind: NotificationKind, enabled: Bool) async {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            let db = try ensureDatabase()
            try db.setNotificationPref(kind, enabled: enabled, updatedAtMs: nowMs)
            // Optimistic local update before server round-trip + refresh so the
            // UI toggle visually commits immediately.
            effective[kind] = enabled
        } catch NotificationPrefsStore.Error.cannotDisableLockedKind {
            logger.warning("NotificationPrefsReader.setEnabled: attempted to disable locked kind \(kind.rawValue, privacy: .public) — UI guard missed")
            // Re-read so the in-memory map reflects the unchanged locked state.
            refresh()
            return
        } catch {
            logger.error("NotificationPrefsReader.setEnabled: \(String(describing: error), privacy: .public)")
            // Re-read so the in-memory map matches what's actually on disk.
            refresh()
            return
        }
        // Best-effort server mirror — failure is swallowed; local persistence
        // already succeeded (UI commit stays; the next setEnabled call gives
        // the mirror another chance).
        if let client = supabaseClient {
            do {
                try await client.upsertNotificationPref(prefKind: kind.rawValue, enabled: enabled)
            } catch {
                logger.warning("NotificationPrefsReader.setEnabled: server mirror failed (local persisted): \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Internal

    private func ensureDatabase() throws -> LeafCore.Database {
        if let db = database { return db }
        let db = try LeafCore.Database.openForWrite(
            at: databaseURL, config: databaseConfig, encryption: databaseEncryption
        )
        self.database = db
        return db
    }

    private static func seedDefaults() -> [NotificationKind: Bool] {
        Dictionary(uniqueKeysWithValues: NotificationKind.allCases.map { ($0, $0.defaultEnabled) })
    }

    private static func defaultConfig() -> DatabaseConfig {
        #if LEAF_PROD
        return ProdConfigs.database
        #else
        return DatabaseConfig.weakDefaults
        #endif
    }

    private static func defaultEncryption() -> EncryptionOptions? {
        #if LEAF_PROD
        return EncryptionOptions(
            keyProvider: .callback { @Sendable in try FileKeyStore.fetchOrCreate() },
            preKeyPragmas: ProdConfigs.sqlcipherPragmasPreKey,
            postKeyPragmas: ProdConfigs.sqlcipherPragmasPostKey
        )
        #else
        return nil
        #endif
    }
}
