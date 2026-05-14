//
//  APNsRegistrationReader.swift
//  Leaf
//
//  Track 5 / S4 — @Observable wrapper around APNsRegistrationService.
//  Exposes lastSyncError surface for Settings → Notifications future UI.
//  Caller (LeafAppDelegate) invokes recordToken from
//  application(_:didRegisterForRemoteNotificationsWithDeviceToken:) callback.
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
final class APNsRegistrationReader {
    private(set) var isRegistered: Bool = false
    private(set) var lastSyncError: String?

    private var service: APNsRegistrationService?
    private var database: LeafCore.Database?
    private let supabase: SupabaseClient
    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "apns-registration")

    init(
        supabase: SupabaseClient,
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = APNsRegistrationReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = APNsRegistrationReader.defaultEncryption()
    ) {
        self.supabase = supabase
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
    }

    func recordToken(_ token: String, environment: String) async {
        do {
            let svc = try ensureService()
            try await svc.recordToken(token, environment: environment)
            isRegistered = true
            lastSyncError = nil
        } catch let err as LeafError {
            lastSyncError = String(describing: err)
            logger.error("APNs token sync failed: \(String(describing: err), privacy: .public)")
        } catch {
            lastSyncError = String(describing: error)
        }
    }

    func retrySyncIfNeeded() async {
        do {
            let svc = try ensureService()
            _ = try await svc.retrySyncIfNeeded()
            lastSyncError = nil
        } catch let err as LeafError {
            lastSyncError = String(describing: err)
        } catch {
            lastSyncError = String(describing: error)
        }
    }

    // MARK: - Internal

    private func ensureService() throws -> APNsRegistrationService {
        if let s = service { return s }
        let db = try LeafCore.Database.openForWrite(
            at: databaseURL, config: databaseConfig, encryption: databaseEncryption
        )
        let svc = APNsRegistrationService(database: db, supabase: supabase)
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
}
