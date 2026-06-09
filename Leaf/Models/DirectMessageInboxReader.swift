//
//  DirectMessageInboxReader.swift
//  Leaf
//
//  Track 5 / S4 — @Observable wrapper around DirectMessageInboxService.
//  Periodically polls Supabase for inbound DMs, decrypts, UPSERTs into mirror,
//  publishes recentMessages + unreadCount surfaces for UI.
//
//  Tick cadence: 30s foreground / 5min background. APNs wake → tickOnce.
//

import CryptoKit
import Foundation
import Observation
import OSLog
import SwiftUI
import LeafCore
#if LEAF_PROD
import LeafCorePrivate
#endif

/// Track 5 / S7 H.1 — conforms to `RealtimeDirectMessageAbsorbing` so
/// `LeafRealtimeService` can inject this reader without an inverse
/// dependency on the app target.
@MainActor
@Observable
final class DirectMessageInboxReader: RealtimeDirectMessageAbsorbing {
    private(set) var recentMessages: [DirectMessageMirrorRow] = []
    private(set) var unreadCount: Int = 0
    /// Per-workspace map of unread inbound DM counts.
    /// Populated on every successful `tick()` + every `absorbRealtimePush(_:)`.
    /// Used by `LeafWorkspaceSwitcher` badge. Key = workspaceID.
    private(set) var unreadCountByWorkspace: [String: Int] = [:]
    private(set) var lastTickError: String?

    /// I10 fix — cache pubkey hex once instead of re-reading IdentityService
    /// on every refreshLocalState (filesystem I/O on every UI poll).
    private var cachedPubkeyHex: String?

    /// Local-notification dedup + first-poll-batch suppression (Set-based; see
    /// `IncomingMessageNotificationTracker`). In-memory → re-primes each launch.
    private var notifTracker = IncomingMessageNotificationTracker()

    /// Set by the composition root (`LeafApp.init`) to fire a local notification
    /// for a new inbound DM. The closure applies master / per-kind prefs + content
    /// (`IncomingMessageNotificationDecider`) and schedules via `LocalMessageNotifier`.
    /// nil in tests / non-notifying contexts.
    var onIncomingInbound: (@MainActor (DirectMessageMirrorRow) -> Void)?

    private var service: DirectMessageInboxService?
    private var database: LeafCore.Database?
    private let supabase: SupabaseClient
    private let activeWorkspaceStore: ActiveWorkspaceStore
    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let keystoreRoot: URL
    private let codec: any DirectMessageBlobCodec
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "dm-inbox")

    init(
        supabase: SupabaseClient,
        activeWorkspaceStore: ActiveWorkspaceStore,
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = DirectMessageInboxReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = DirectMessageInboxReader.defaultEncryption(),
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        codec: any DirectMessageBlobCodec = DirectMessageInboxReader.defaultCodec()
    ) {
        self.supabase = supabase
        self.activeWorkspaceStore = activeWorkspaceStore
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
        self.keystoreRoot = keystoreRoot
        self.codec = codec
    }

    /// Schedule a full poll + decode + UPSERT cycle.
    func tick() async {
        guard let wid = activeWorkspaceStore.activeWorkspaceID else { return }
        let svc: DirectMessageInboxService
        do {
            svc = try ensureService()
        } catch {
            lastTickError = "DB open failed: \(error)"
            return
        }
        do {
            let newRows = try await svc.tickReturningNewRows(workspaceID: wid)
            refreshLocalState(workspaceID: wid)
            refreshUnreadCounts()
            // Polling notifications: first batch per workspace is backlog (suppressed);
            // subsequent new inbound-unread rows fire a local notification.
            let notifiable = Set(
                notifTracker.notifiablePolledMessageIDs(
                    workspaceID: wid, messageIDs: newRows.map { $0.messageID }))
            for row in newRows
            where notifiable.contains(row.messageID)
                && row.direction == .inbound && row.readAtMs == nil {
                onIncomingInbound?(row)
            }
            lastTickError = nil
        } catch {
            lastTickError = String(describing: error)
        }
    }

    /// Eager fetch of a single message — driven by APNs wake.
    func tickOnce(workspaceID: String, forMessageID messageID: String) async {
        let svc: DirectMessageInboxService
        do {
            svc = try ensureService()
        } catch {
            lastTickError = "DB open failed: \(error)"
            return
        }
        _ = try? await svc.tickOnce(workspaceID: workspaceID, forMessageID: messageID)
        refreshLocalState(workspaceID: workspaceID)
    }

    /// Recomputes `unreadCountByWorkspace` via a single SQL aggregate over all
    /// workspaces. Cheap — uses the `idx_messages_mirror_unread` partial index.
    /// Called after every successful `tick()` and every `absorbRealtimePush(_:)`.
    func refreshUnreadCounts() {
        guard let db = database else { return }
        do {
            unreadCountByWorkspace = try db.readUnreadDMCountByWorkspace()
        } catch {
            logger.error("refreshUnreadCounts failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Track 5 / S8 / T0 — Phase H Realtime decryption wiring.
    ///
    /// Forwarder for the injected decryptor closure used by LeafRealtimeService.
    /// Delegates to the wrapped `DirectMessageInboxService.decryptOnly(_:)`. The
    /// reader is the env-injected boundary; the service stays private.
    func decryptOnly(_ input: EncryptedDirectMessageInput) throws -> DirectMessagePlaintext {
        let svc = try ensureService()
        return try svc.decryptOnly(input)
    }

    /// Realtime push handler — UPSERTs a single inbound DM row + refreshes counts.
    /// Called by LeafRealtimeService when a Realtime POSTGRES_CHANGES INSERT/UPDATE
    /// event fires on `direct_messages` for this device's pubkey.
    /// Falls back gracefully on DB unavailability: sets `lastTickError` + skips.
    func absorbRealtimePush(_ row: DirectMessageMirrorRow) async {
        let svc: DirectMessageInboxService
        do {
            svc = try ensureService()
        } catch {
            lastTickError = "DB open failed (realtime push): \(error)"
            return
        }
        // Pre-upsert: was this message already in this device's mirror? Realtime
        // delivers both INSERT and UPDATE events (read_at / done_at / cross_post),
        // and LeafRealtimeService routes UPDATEs through this same path. Notify
        // only for messages NEW to the mirror, so a column UPDATE — or a
        // post-restart re-delivery of a message we already hold — never fires a
        // banner. This is restart-safe (the mirror persists) where the in-memory
        // dedup set is not; the set still guards the realtime/polling race below.
        let alreadyInMirror: Bool = {
            let existing = try? database?.readSQL {
                try MessagesMirrorStore.read(messageID: row.messageID, in: $0)
            }
            return (existing ?? nil) != nil
        }()
        do {
            try svc.absorbRealtimePush(row)
            if row.workspaceID == activeWorkspaceStore.activeWorkspaceID {
                refreshLocalState(workspaceID: row.workspaceID)
            }
            refreshUnreadCounts()
            // New-to-mirror inbound-unread row → notify once (set dedups the
            // realtime/polling in-flight race; mirror check dedups updates/restart).
            if !alreadyInMirror, row.direction == .inbound, row.readAtMs == nil,
               notifTracker.shouldNotifyRealtime(messageID: row.messageID) {
                onIncomingInbound?(row)
            }
            lastTickError = nil
        } catch {
            lastTickError = "Realtime push absorb failed: \(error)"
        }
    }

    /// Refresh published surfaces from local mirror — called after every successful tick.
    func refreshLocalState(workspaceID: String) {
        guard let db = database else { return }
        do {
            let recent = try db.readSQL {
                try MessagesMirrorStore.readRecent(workspaceID: workspaceID, limit: 50, in: $0)
            }
            recentMessages = recent
            if let pubkey = cachedPubkey() {
                let unread = try db.readSQL {
                    try MessagesMirrorStore.readUnreadInbound(
                        workspaceID: workspaceID, recipientPubkeyHex: pubkey, in: $0
                    )
                }
                unreadCount = unread.count
            }
        } catch {
            logger.error("refreshLocalState failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// I10 fix — Track 5 / S4 Stage 6 review.
    /// IdentityService.ensureLocalIdentity does filesystem I/O on every call. Cache
    /// the derived pubkey hex once per reader lifetime; identity is set-once at
    /// onboarding and never rotates within a session.
    private func cachedPubkey() -> String? {
        if let cached = cachedPubkeyHex { return cached }
        guard let priv = try? IdentityService.ensureLocalIdentity(at: keystoreRoot) else { return nil }
        let hex = priv.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        cachedPubkeyHex = hex
        return hex
    }

    // MARK: - Mark read / done (proxy to SupabaseClient + local refresh)

    /// Server PATCH for read state + local mirror refresh via next-tick.
    /// Follows the I4 fix pattern from Track 5 / S4 Stage 6:
    /// supabase.markRead → server PATCH; local mirror is refreshed by calling
    /// refreshLocalState after the write completes. Full local UPDATE (mirror store)
    /// would require a Database write handle; deferred to Phase H composition root
    /// which wires a DirectMessageService with both supabase + database handles.
    /// Until then, the unread count refreshes on the next foreground tick.
    func markRead(messageID: String) async {
        let nowISO: String = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.string(from: Date())
        }()
        try? await supabase.markRead(messageID: messageID, readAtISO: nowISO)
        refreshUnreadCounts()
    }

    /// Track 5 / S8 T6 — Optimistic local mark-done + server PATCH + retry-queue flag.
    ///
    /// Flow:
    ///   1. Compute now timestamp + cached self pubkey.
    ///   2. Local mirror UPDATE FIRST — done_at + done_by_pubkey + clears
    ///      `pending_mark_done`. User sees the row marked done immediately;
    ///      latency-tolerant whether server PATCH succeeds or not.
    ///   3. Server PATCH attempt.
    ///      - Success: nothing more to do (local already at desired state).
    ///      - Failure (network / 5xx / RLS): set `pending_mark_done = 1` so
    ///        `PendingMarkDoneRetryService.tick()` retries on the daily-tick
    ///        scheduler driven from `RootView.task`.
    ///   4. Refresh local UI snapshot so the done badge renders immediately.
    ///
    /// Called from:
    ///   - In-app [Mark Done] button (TeamView Task message card).
    ///   - APNs `dm.markDone` action handler (LeafAppDelegate) — runs WITHOUT
    ///     opening the app; the optimistic write means recipient sees the
    ///     correct state on next foreground without waiting for server PATCH.
    func markDone(messageID: String) async {
        let pubkey = cachedPubkey() ?? ""
        let nowDate = Date()
        let nowMs = Int64(nowDate.timeIntervalSince1970 * 1000)
        let nowISO: String = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.string(from: nowDate)
        }()

        // 1. Optimistic local UPDATE — UI reflects done immediately.
        //    A DB-open failure here is silent-skip: extremely rare (only at
        //    cold-boot races), and falling through to the server PATCH still
        //    yields server-side correctness on the next inbox tick.
        do {
            let svc = try ensureService()
            try svc.markDoneLocalOptimistic(
                messageID: messageID,
                atMs: nowMs,
                doneByPubkeyHex: pubkey
            )
            refreshLocalStateIfActive(messageID: messageID)
        } catch {
            logger.warning("optimistic markDone local UPDATE failed: \(String(describing: error), privacy: .public)")
        }

        // 2. Attempt server PATCH.
        do {
            try await supabase.markDone(
                messageID: messageID,
                doneAtISO: nowISO,
                doneByPubkeyHex: pubkey
            )
        } catch {
            // 3. Network / RLS failure — flip retry-queue flag for daily tick.
            //    A flag-set failure here is silent-skip: worst case the row
            //    is not retried until the next time the user marks any task
            //    done (which will trigger a fresh local UPDATE path).
            do {
                let svc = try ensureService()
                try svc.setPendingMarkDoneFlag(messageID: messageID, pending: true)
            } catch {
                logger.warning("setPendingMarkDone failed (retry suppressed): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Refresh local UI snapshot after an optimistic UPDATE so the done badge
    /// renders without waiting for the next 30s tick. Cheap (single SELECT).
    private func refreshLocalStateIfActive(messageID: String) {
        guard let wid = activeWorkspaceStore.activeWorkspaceID else { return }
        refreshLocalState(workspaceID: wid)
    }

    // MARK: - Internal

    private func ensureService() throws -> DirectMessageInboxService {
        if let s = service { return s }
        let db = try LeafCore.Database.openForWrite(
            at: databaseURL, config: databaseConfig, encryption: databaseEncryption
        )
        let svc = DirectMessageInboxService(
            database: db,
            supabase: supabase,
            codec: codec,
            keystoreRoot: keystoreRoot
        )
        self.database = db
        self.service = svc
        return svc
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

    private static func defaultCodec() -> any DirectMessageBlobCodec {
        #if LEAF_PROD
        return LeafCorePrivate.ProdDirectMessageBlobCodec()
        #else
        return UnimplementedDirectMessageBlobCodec()
        #endif
    }
}
