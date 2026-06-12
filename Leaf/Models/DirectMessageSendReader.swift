//
//  DirectMessageSendReader.swift
//  Leaf
//
//  Track 5 / S4 — @Observable wrapper for DirectMessageService.send. State machine
//  drives SendDirectMessageSheet: .idle → .sending → (.sent / .error).
//
//  Lazy-init pattern mirrors InviteAcceptReader. SupabaseClient injected;
//  Database + service spin up on first send.
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
final class DirectMessageSendReader {
    enum State: Equatable {
        case idle
        case sending
        /// Track 5 / S6 T12 — extended with `crossPost` so the Send sheet can
        /// render per-channel status rows (Leaf locked + Slack + Linear).
        /// Empty `CrossPostStatuses` (both slots nil) means caller didn't
        /// request any cross-post; UI degrades to S4-style single success row.
        case sent(
            messageID: String,
            status: SentDirectMessage.PushDispatchStatus,
            crossPost: CrossPostStatuses
        )
        case error(message: String)
    }

    private(set) var state: State = .idle

    private var service: DirectMessageService?
    private var database: LeafCore.Database?

    private let supabase: SupabaseClient
    private let activeWorkspaceStore: ActiveWorkspaceStore
    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let keystoreRoot: URL
    private let codec: any DirectMessageBlobCodec
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "dm-send")

    init(
        supabase: SupabaseClient,
        activeWorkspaceStore: ActiveWorkspaceStore,
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = DirectMessageSendReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = DirectMessageSendReader.defaultEncryption(),
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        codec: any DirectMessageBlobCodec = DirectMessageSendReader.defaultCodec()
    ) {
        self.supabase = supabase
        self.activeWorkspaceStore = activeWorkspaceStore
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
        self.keystoreRoot = keystoreRoot
        self.codec = codec
    }

    func reset() {
        state = .idle
    }

    /// Track C (UC-4) — sender-side context snapshot for handoff DMs: projects
    /// `QueryEngine.currentWork` (work-aware after B0) into the structured
    /// card. nil when the DB is missing or no line carries data — the sheet
    /// hides the preview and sends a plain handoff.
    func buildContextSnapshot(title: String?) async -> HandoffContextSnapshot? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        let url = databaseURL
        let config = databaseConfig
        let encryption = databaseEncryption
        return await Task.detached(priority: .userInitiated) { () -> HandoffContextSnapshot? in
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let engine = QueryEngine(
                dbURL: url, dbConfig: config, dbEncryption: encryption,
                detectorMoat: .publicSubstrate)
            guard let work = try? engine.currentWork(nowMs: nowMs) else { return nil }
            let snapshot = HandoffSnapshotBuilder.build(from: work, title: title, nowMs: nowMs)
            return snapshot.hasAnyLine ? snapshot : nil
        }.value
    }

    /// Track 5 / S6 T12 — extended with `crossPostSlack` / `crossPostLinear`.
    /// Both default to nil (S4 single-channel parity). When the Send sheet
    /// passes one or both, DirectMessageService runs Slack + Linear legs in
    /// parallel (§9.3 — failure NEVER throws; the DM row persists regardless).
    /// On success, `.sent` carries the merged `CrossPostStatuses` for the
    /// status-row renderer.
    func send(
        recipientPubkeyHex: String,
        recipientMemberID: String?,
        kind: DirectMessageKind,
        body: String,
        notify: Bool,
        replyTo: String? = nil,
        contextSnapshot: HandoffContextSnapshot? = nil,
        crossPostSlack: SlackCrossPostRequest? = nil,
        crossPostLinear: LinearCrossPostRequest? = nil
    ) async {
        guard let workspaceID = activeWorkspaceStore.activeWorkspaceID else {
            state = .error(message: "No active workspace")
            return
        }

        state = .sending

        let svc: DirectMessageService
        do {
            svc = try ensureService()
        } catch {
            state = .error(message: "Failed to open DB: \(error)")
            return
        }

        do {
            let result = try await svc.send(
                workspaceID: workspaceID,
                recipientPubkeyHex: recipientPubkeyHex,
                recipientMemberID: recipientMemberID,
                kind: kind,
                body: body,
                notify: notify,
                replyTo: replyTo,
                contextSnapshot: contextSnapshot,
                crossPostSlack: crossPostSlack,
                crossPostLinear: crossPostLinear
            )
            state = .sent(
                messageID: result.messageID,
                status: result.pushDispatchStatus,
                crossPost: result.crossPostStatuses
            )
        } catch let err as LeafError {
            state = .error(message: Self.humanMessage(for: err))
        } catch let err as SupabaseError {
            state = .error(message: Self.humanMessage(for: err))
        } catch {
            state = .error(message: "Couldn't send. Please try again.")
        }
    }

    /// I9 fix — Track 5 / S4 Stage 6 review:
    /// Map raw errors to user-readable strings. Dev / log paths still see the
    /// underlying enum via separate logging; UI surfaces just the user copy.
    private static func humanMessage(for err: LeafError) -> String {
        switch err {
        case .invalidPayload:                return "Message is empty."
        case .directMessageBodyTooLarge:     return "Message is too long (max 64KB)."
        case .databaseUnavailable:           return "Workspace not loaded. Try reopening the app."
        case .apnsPushDispatchFailed:        return "Message sent. Push notification deferred — recipient will see it on next sync."
        case .apnsRegistrationFailed:        return "Couldn't register for push. Message persists."
        default:                             return "Couldn't send. Please try again."
        }
    }

    private static func humanMessage(for err: SupabaseError) -> String {
        switch err {
        case .unauthorized, .identityClaimMissing:
            return "Not signed in. Restart the app."
        case .forbidden:
            return "Server rejected this message (permission)."
        case .rateLimited:
            return "Sending too fast. Try again in a moment."
        case .transport:
            return "Network error. Check your connection."
        case .serverError:
            return "Server error. Try again later."
        default:
            return "Couldn't send. Please try again."
        }
    }

    // MARK: - Internal lazy bootstrap

    private func ensureService() throws -> DirectMessageService {
        if let s = service { return s }
        let db = try LeafCore.Database.openForWrite(
            at: databaseURL, config: databaseConfig, encryption: databaseEncryption
        )
        let svc = DirectMessageService(
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
