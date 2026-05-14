//
//  InviteAcceptReader.swift
//  Leaf
//
//  Track 5 / S3 — @Observable wrapper for InviteAcceptService single-call acceptInvite(url:displayName:otp:).
//  State machine drives AcceptInviteSheet: .idle → .previewing → (.joining → .joined / .otpPrompt / .error).
//
//  Lazy-init: Database + SupabaseClient + InviteAcceptService spin up on first use; same
//  instance reused per app session.
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

@MainActor
@Observable
final class InviteAcceptReader {
    enum State: Equatable {
        case idle
        case previewing(preview: URLPreview, url: URL)
        case joining(url: URL)
        case otpPrompt(preview: URLPreview, url: URL, lastError: String?)
        case joined(orgName: String, memberCount: Int, syncPending: Bool)
        case error(message: String, recoverable: Bool, retryURL: URL?)
    }

    private(set) var state: State = .idle

    /// Invitee onboarding writes displayName once; AcceptInviteSheet auto-uses on submit.
    @ObservationIgnored
    @AppStorage("inviteeDisplayName") private(set) var savedDisplayName: String = ""

    func saveInviteeDisplayName(_ name: String) {
        savedDisplayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var service: InviteAcceptService?
    private var database: LeafCore.Database?

    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let keystoreRoot: URL
    private let inviteKDF: any InviteKDF
    private let inviteBlobCodec: any InviteBlobCodec
    private let supabase: SupabaseClient
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "invite-accept")

    init(
        supabase: SupabaseClient,
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = InviteAcceptReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = InviteAcceptReader.defaultEncryption(),
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        inviteKDF: any InviteKDF = InviteAcceptReader.defaultInviteKDF(),
        inviteBlobCodec: any InviteBlobCodec = InviteAcceptReader.defaultInviteBlobCodec()
    ) {
        self.supabase = supabase
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
        self.keystoreRoot = keystoreRoot
        self.inviteKDF = inviteKDF
        self.inviteBlobCodec = inviteBlobCodec
    }

    /// Invitee's own X25519 pubkey hex (lowercase) — onboarding shows to copy + send to admin.
    /// Idempotent — generates only if file doesn't yet exist.
    func myPubkeyHex() throws -> String {
        let priv = try IdentityService.ensureLocalIdentity(at: keystoreRoot)
        return priv.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Track 5 / S3 — deep-link entry. Synchronous URL parse, transitions to .previewing.
    func fetch(inviteURL url: URL) {
        switch InviteAcceptService.preview(url: url) {
        case .success(let preview):
            state = .previewing(preview: preview, url: url)
        case .failure:
            state = .error(message: "Invite link is broken. Ask admin to copy and resend it.",
                           recoverable: false, retryURL: nil)
        }
    }

    /// Track 5 / S3 — user clicked [Join] (or re-submitted with OTP). Single-call accept.
    func join(displayName: String?, otp: String?) {
        let url: URL
        let previewSnapshot: URLPreview
        switch state {
        case .previewing(let preview, let u):
            url = u; previewSnapshot = preview
        case .otpPrompt(let preview, let u, _):
            url = u; previewSnapshot = preview
        default:
            return  // not in a joinable state
        }
        let resolvedName: String = {
            let trimmed = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            let stored = savedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stored.isEmpty { return stored }
            return NSFullUserName()
        }()
        state = .joining(url: url)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let svc = try self.ensureService()
                let accepted = try await svc.acceptInvite(url: url, displayName: resolvedName, otp: otp)
                let count: Int
                if let db = self.database,
                   let members = try? db.readTeamMembers(workspaceID: accepted.orgID) {
                    count = members.count
                } else {
                    count = 0
                }
                let syncPending: Bool
                if case .pending = accepted.membershipSyncStatus { syncPending = true } else { syncPending = false }
                self.state = .joined(orgName: accepted.orgName, memberCount: count, syncPending: syncPending)
            } catch LeafError.inviteOTPRequired {
                self.state = .otpPrompt(preview: previewSnapshot, url: url, lastError: nil)
            } catch LeafError.inviteOTPInvalid {
                self.state = .otpPrompt(preview: previewSnapshot, url: url,
                                        lastError: "OTP doesn't match. Try again.")
            } catch {
                self.logger.error("acceptInvite failed: \(String(describing: error), privacy: .public)")
                self.state = .error(message: self.userFacingMessage(for: error),
                                    recoverable: self.isRecoverable(error),
                                    retryURL: self.isRecoverable(error) ? url : nil)
            }
        }
    }

    func reset() {
        state = .idle
    }

    // MARK: - Internals

    private func ensureService() throws -> InviteAcceptService {
        if let service { return service }
        let db = try LeafCore.Database.openForWrite(
            at: databaseURL,
            config: databaseConfig,
            encryption: databaseEncryption
        )
        let svc = InviteAcceptService(
            database: db,
            supabase: supabase,
            inviteKDF: inviteKDF,
            inviteBlobCodec: inviteBlobCodec,
            keystoreRoot: keystoreRoot
        )
        self.database = db
        self.service = svc
        return svc
    }

    private func userFacingMessage(for error: Error) -> String {
        if let leafErr = error as? LeafError {
            switch leafErr {
            case .invalidPayload:
                return "Display name can't be empty."
            case .inviteAlreadyAccepted:
                return "You're already in this team."
            case .inviteBlobMalformed:
                return "Invite link is corrupted. Ask admin to send a new one."
            case .relayUnreachable(let reason):
                return "Couldn't reach the server (\(reason)). Check your network and try again."
            case .keyFileUnavailable, .keyFileCorrupted:
                return "Couldn't access local keystore. Try restarting the app."
            case .databaseUnavailable:
                return "Couldn't open local database. Try restarting the app."
            case .inviteAlreadyConsumed:
                return "This invite has expired or already been used."
            case .inviteURLMalformed:
                return "Invite link is broken. Ask admin to copy and resend it."
            default:
                return "Couldn't accept the invite. See Console for details."
            }
        }
        return "Couldn't accept the invite. See Console for details."
    }

    private func isRecoverable(_ error: Error) -> Bool {
        guard let leafErr = error as? LeafError else { return false }
        switch leafErr {
        case .relayUnreachable, .invalidPayload:
            return true
        default:
            return false
        }
    }

    nonisolated private static func defaultConfig() -> DatabaseConfig {
        #if LEAF_PROD
        return ProdConfigs.database
        #else
        return .weakDefaults
        #endif
    }

    nonisolated private static func defaultEncryption() -> EncryptionOptions? {
        #if LEAF_PROD
        return EncryptionOptions(
            keyProvider: .callback { @Sendable in
                try FileKeyStore.fetchOrCreate()
            },
            preKeyPragmas: ProdConfigs.sqlcipherPragmasPreKey,
            postKeyPragmas: ProdConfigs.sqlcipherPragmasPostKey
        )
        #else
        return nil
        #endif
    }

    nonisolated private static func defaultInviteKDF() -> any InviteKDF {
        #if LEAF_PROD
        return ProdInviteKDF()
        #else
        return UnimplementedInviteKDF()
        #endif
    }

    nonisolated private static func defaultInviteBlobCodec() -> any InviteBlobCodec {
        #if LEAF_PROD
        return ProdInviteBlobCodec()
        #else
        return UnimplementedInviteBlobCodec()
        #endif
    }
}
