//
//  InviteAcceptReader.swift
//  Leaf
//
//  Phase 5.2.E — @Observable wrapper для InviteAcceptService. Lazy-init
//  Database + RelayClient + service. State machine drives AcceptInviteSheet
//  + Onboarding `.team` step + OrganizationView empty-state second CTA.
//
//  Two-step flow per decomposition §2 D4: relay GET one-shot consume
//  (fetch), затем blob держится в RAM пока юзер вводит OTP — каждая
//  попытка decode локальная (AES-GCM tag fail на wrong OTP). После 5
//  failed attempts UI surfaces "Discard + ask admin" CTA.
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
        case fetching
        case otpEntry(blob: InviteBlob, attempts: Int, prefillOTP: String?)
        case accepting
        case success(orgName: String, memberCount: Int)
        case error(message: String, recoverable: Bool)
    }

    private(set) var state: State = .idle

    /// Phase 5.5.B — invitee onboarding записывает displayName на JoinTeamStepView; AcceptInviteSheet
    /// auto-uses на submit. Если пусто — fall back to NSFullUserName (set'ится один раз on first read).
    @ObservationIgnored
    @AppStorage("inviteeDisplayName") private(set) var savedDisplayName: String = ""

    /// Public setter для CreateTeam / JoinTeam onboarding views. Read-only вне этого Reader'а.
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
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "invite-accept")

    init(
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = InviteAcceptReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = InviteAcceptReader.defaultEncryption(),
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        inviteKDF: any InviteKDF = InviteAcceptReader.defaultInviteKDF(),
        inviteBlobCodec: any InviteBlobCodec = InviteAcceptReader.defaultInviteBlobCodec()
    ) {
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
        self.keystoreRoot = keystoreRoot
        self.inviteKDF = inviteKDF
        self.inviteBlobCodec = inviteBlobCodec
    }

    /// Returns invitee's own X25519 pubkey hex (lowercase) — рендерим в Step 1
    /// AcceptInviteSheet чтобы юзер мог скопировать и отправить admin'у.
    /// Idempotent — генерирует только если файла ещё нет.
    func myPubkeyHex() throws -> String {
        let priv = try IdentityService.ensureLocalIdentity(at: keystoreRoot)
        return priv.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()
    }

    func fetch(token: String) {
        state = .fetching
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let svc = try self.ensureService()
                let blob = try await svc.fetchInvite(token: token)
                self.state = .otpEntry(blob: blob, attempts: 0, prefillOTP: nil)
            } catch {
                self.logger.error("fetchInvite failed: \(String(describing: error), privacy: .public)")
                self.state = .error(message: self.userFacingMessage(for: error),
                                    recoverable: self.isRecoverable(error))
            }
        }
    }

    /// Phase 5.5.B — single deep-link path: parse + fetch + auto-prefill OTP.
    func fetch(inviteURL: URL) {
        state = .fetching
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let svc = try self.ensureService()
                let result = try await svc.fetchInvite(inviteURL: inviteURL)
                self.state = .otpEntry(blob: result.blob, attempts: 0, prefillOTP: result.otp)
            } catch {
                self.logger.error("fetchInvite(URL) failed: \(String(describing: error), privacy: .public)")
                self.state = .error(message: self.userFacingMessage(for: error),
                                    recoverable: self.isRecoverable(error))
            }
        }
    }

    func submitOTP(otp: String, displayName: String? = nil) {
        guard case .otpEntry(let blob, let attempts, _) = state else { return }
        let resolvedName: String = {
            let trimmed = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            let stored = savedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stored.isEmpty { return stored }
            return NSFullUserName()
        }()
        state = .accepting
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let svc = try self.ensureService()
                let accepted = try await svc.acceptInvite(blob: blob,
                                                          otp: otp,
                                                          displayName: resolvedName)
                let count: Int
                if let db = self.database,
                   let members = try? db.readTeamMembers(orgID: accepted.orgID) {
                    count = members.count
                } else {
                    count = 0
                }
                self.state = .success(orgName: accepted.orgName, memberCount: count)
            } catch LeafError.inviteOTPInvalid {
                // Stay in OTP entry — invitee retries locally без re-fetch.
                self.state = .otpEntry(blob: blob, attempts: attempts + 1, prefillOTP: nil)
            } catch {
                self.logger.error("acceptInvite failed: \(String(describing: error), privacy: .public)")
                self.state = .error(message: self.userFacingMessage(for: error),
                                    recoverable: self.isRecoverable(error))
            }
        }
    }

    func discardAndReset() {
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
        let relay = RelayClient()
        let svc = InviteAcceptService(
            database: db,
            relayClient: relay,
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
                return "Token and display name can’t be empty."
            case .inviteNotFound:
                return "Invite not found, expired, or already used. Ask admin to send a new one."
            case .inviteAlreadyAccepted:
                return "An organization already exists on this device."
            case .inviteBlobMalformed:
                return "Invite is corrupted. Ask admin to send a new one."
            case .relayUnreachable(let reason):
                return "Couldn’t reach the relay (\(reason)). Check your network and try again."
            case .keyFileUnavailable, .keyFileCorrupted:
                return "Couldn’t access local keystore. Try restarting the app."
            case .databaseUnavailable:
                return "Couldn’t open local database. Try restarting the app."
            case .notImplemented:
                return "Invite acceptance isn’t available in this build."
            case .inviteAlreadyConsumed:
                return "Invite was already opened or expired. Ask admin to send a new one."
            case .inviteURLMalformed:
                return "Invite link is broken. Ask admin to copy and resend it."
            default:
                return "Couldn’t accept the invite. See Console for details."
            }
        }
        return "Couldn’t accept the invite. See Console for details."
    }

    /// Recoverable = invitee can correct + retry within current sheet session.
    /// Non-recoverable = sheet should surface "Done"/"Close" only — re-entry
    /// requires admin to send a new invite or wipe local state.
    private func isRecoverable(_ error: Error) -> Bool {
        guard let leafErr = error as? LeafError else { return false }
        switch leafErr {
        case .relayUnreachable, .invalidPayload:
            return true
        case .inviteAlreadyAccepted, .inviteNotFound, .inviteBlobMalformed,
             .keyFileUnavailable, .keyFileCorrupted, .databaseUnavailable, .notImplemented,
             .inviteAlreadyConsumed, .inviteURLMalformed:
            return false
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
