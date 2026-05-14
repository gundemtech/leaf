//
//  SupabaseSessionStore.swift
//  LeafCore
//
//  Track 5 / S4 — file-backed persistence for Supabase refresh_token. Closes S3
//  carry-over I3 (re-signup on every cold launch). Persisted JSON is stored in
//  the same keystore root that holds workspace teamKeys (per Track 5 contract
//  §14.1 amendment file-based discipline). 0o600 perms enforced after write.
//
//  Threat model: refresh_token at rest in keystore is equivalent confidentiality
//  to teamKey rows already there. No incremental risk.
//
//  Failure modes (LeafError.supabaseSessionStoreFailure): disk read/write error,
//  JSON decode failure, permissions enforcement failure. Caller logs + falls back
//  to in-memory session (subsequent cold launch repeats fresh signup).
//

import Foundation

public struct SupabaseSessionStore: Sendable {
    private let path: URL

    public init(at keystoreRoot: URL) {
        self.path = keystoreRoot.appendingPathComponent("supabase-session.json")
    }

    /// Read persisted session. Returns nil on missing file (fresh device). Throws
    /// on malformed JSON / IO error (caller logs + proceeds with fresh signup).
    public func read() throws -> PersistedSession? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw LeafError.supabaseSessionStoreFailure(reason: "read failed: \(error)")
        }
        do {
            return try JSONDecoder().decode(PersistedSession.self, from: data)
        } catch {
            throw LeafError.supabaseSessionStoreFailure(reason: "decode failed: \(error)")
        }
    }

    /// Atomic write to disk + 0o600 perm enforcement. Caller invokes after every
    /// successful auth refresh (or signup that captures refresh_token).
    public func write(_ session: PersistedSession) throws {
        try ensureDirectoryExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(session)
        } catch {
            throw LeafError.supabaseSessionStoreFailure(reason: "encode failed: \(error)")
        }
        do {
            try data.write(to: path, options: [.atomic])
        } catch {
            throw LeafError.supabaseSessionStoreFailure(reason: "write failed: \(error)")
        }
        try setStrictPermissions()
    }

    /// Delete persisted session (sign-out path).
    public func clear() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else { return }
        do {
            try fm.removeItem(at: path)
        } catch {
            throw LeafError.supabaseSessionStoreFailure(reason: "clear failed: \(error)")
        }
    }

    // MARK: - Internal

    private func ensureDirectoryExists() throws {
        let fm = FileManager.default
        let dir = path.deletingLastPathComponent()
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: dir.path, isDirectory: &isDir) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            } catch {
                throw LeafError.supabaseSessionStoreFailure(reason: "mkdir failed: \(error)")
            }
        }
    }

    private func setStrictPermissions() throws {
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path.path
            )
        } catch {
            throw LeafError.supabaseSessionStoreFailure(reason: "chmod failed: \(error)")
        }
    }
}

/// Phase Track-5 S4 — JSON shape persisted on disk.
public struct PersistedSession: Codable, Sendable, Equatable {
    public let refreshToken: String
    public let userID: String
    public let savedAtMs: Int64

    public init(refreshToken: String, userID: String, savedAtMs: Int64) {
        self.refreshToken = refreshToken
        self.userID = userID
        self.savedAtMs = savedAtMs
    }

    private enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
        case userID       = "user_id"
        case savedAtMs    = "saved_at_ms"
    }
}
