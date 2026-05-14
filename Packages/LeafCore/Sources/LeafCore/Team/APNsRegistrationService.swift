//
//  APNsRegistrationService.swift
//  LeafCore
//
//  Track 5 / S4 — APNs token registration orchestrator. Captures token from
//  macOS push registration callback, persists local mirror in apns_token_local
//  (singleton per device), pushes to Supabase apns_tokens via SupabaseClient,
//  marks server_synced_at_ms on success.
//
//  Caller (LeafAppDelegate) invokes recordToken from
//  application(_:didRegisterForRemoteNotificationsWithDeviceToken:) callback;
//  retrySyncIfNeeded fires on scenePhase=active to recover from earlier sync
//  failures.
//

import Foundation

public actor APNsRegistrationService {
    private let database: Database
    private let supabase: SupabaseClient
    private let deviceID: String
    private let now: @Sendable () -> Date

    public init(
        database: Database,
        supabase: SupabaseClient,
        deviceID: String = APNsRegistrationService.defaultDeviceID(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.supabase = supabase
        self.deviceID = deviceID
        self.now = now
    }

    /// Record token locally (UPSERT into apns_token_local), then push to Supabase.
    /// On Supabase failure, local row exists with `server_synced_at_ms IS NULL`
    /// for `retrySyncIfNeeded` to recover.
    public func recordToken(_ apnsToken: String, environment: String) async throws {
        let nowMs = Int64(now().timeIntervalSince1970 * 1000)

        try database.writeSQL { db in
            try APNsTokenLocalStore.upsert(
                deviceID: deviceID,
                apnsToken: apnsToken,
                environment: environment,
                registeredAtMs: nowMs,
                in: db
            )
        }

        do {
            try await supabase.registerAPNsToken(
                deviceID: deviceID,
                apnsToken: apnsToken,
                environment: environment
            )
        } catch {
            throw LeafError.apnsRegistrationFailed(reason: String(describing: error))
        }

        try database.writeSQL { db in
            try APNsTokenLocalStore.markServerSynced(
                deviceID: deviceID, atMs: nowMs, in: db
            )
        }
    }

    /// Retry Supabase push if local row exists with server_synced_at_ms IS NULL.
    /// No-op when row missing or already synced.
    @discardableResult
    public func retrySyncIfNeeded() async throws -> Bool {
        let row = try database.writeSQL { db in
            try APNsTokenLocalStore.read(deviceID: deviceID, in: db)
        }
        guard let row, row.serverSyncedAtMs == nil else { return false }

        do {
            try await supabase.registerAPNsToken(
                deviceID: row.deviceID,
                apnsToken: row.apnsToken,
                environment: row.environment
            )
        } catch {
            throw LeafError.apnsRegistrationFailed(reason: String(describing: error))
        }

        let nowMs = Int64(now().timeIntervalSince1970 * 1000)
        try database.writeSQL { db in
            try APNsTokenLocalStore.markServerSynced(
                deviceID: row.deviceID, atMs: nowMs, in: db
            )
        }
        return true
    }

    // MARK: - Default deviceID

    /// IOPlatformUUID-based stable device identifier. Falls back to a per-launch
    /// UUID if hardware UUID is inaccessible (testing / sandbox restrictions).
    public static func defaultDeviceID() -> String {
        #if os(macOS)
        if let hw = ioPlatformUUID() {
            return hw
        }
        #endif
        return UUID().uuidString.lowercased()
    }

    #if os(macOS)
    private static func ioPlatformUUID() -> String? {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard platformExpert != 0 else { return nil }
        defer { IOObjectRelease(platformExpert) }
        guard let serialNumberAsCFString = IORegistryEntryCreateCFProperty(
            platformExpert, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        let cfString = serialNumberAsCFString.takeRetainedValue() as? String
        return cfString?.lowercased()
    }
    #endif
}

#if os(macOS)
import IOKit
#endif
