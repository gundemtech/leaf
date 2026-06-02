import Foundation
import Security

/// Phase 5.1.D — file-based key writer/reader for team primitives:
/// X25519 long-term private (per device, contract §7) + per-rotation teamKey
/// files (current + history, contract §7 "key lifecycle"). They live next to `db.key`
/// (FileKeyStore) in `~/Library/Application Support/Leaf/keystore/`.
///
/// Protection: file permissions 0o600 + FileVault. Sensitivity comparable to the
/// DB file itself (`events.sqlite`).
///
/// Layout (Track-5 S2 multi-workspace):
/// - `<root>/x25519.priv` — 32 bytes raw, single file per device. NOT
///   workspace-scoped — this is a long-term device identity, used for invite
///   handshake ECDH (contract §7).
/// - `<root>/workspaces/<workspace_id>/team-keys/<UUID>.key` — 32 bytes raw,
///   one file per rotation per workspace. Filename = `team_keys.id` (UUID
///   lowercase canonical). The "current rotation" is determined via
///   `Database.readActiveTeamKey(workspaceID:)` → file lookup by id within
///   workspace sub-folder. No separate "current" pointer — DB-driven, no
///   split-brain risk. Cross-workspace read fails by path (OS-enforced
///   isolation, not naming-discipline-dependent).
/// - Legacy alpha.x layout `<root>/team-keys/<UUID>.key` (pre-M019,
///   single-org era) — best-effort relocation by `relocateLegacyTeamKeys`,
///   invoked from M019 Step 9 for alpha.x upgrade compatibility.
///
/// Concurrency: atomic write (`Data.write` with `.atomic` → POSIX `rename(2)`).
/// Mirror discipline of `FileKeyStore`. Write-then-read-back-verify is not needed —
/// 5.1.D writers are called only from `WorkspaceService.createWorkspace`
/// (single point per workspace), not from distributed processes (mirrors the
/// KeyStore-for-DB pattern, where the race matters; the team keystore is materialized
/// once per workspace).
public enum TeamKeystore {
    public static let x25519PrivateFilename = "x25519.priv"
    public static let teamKeysSubdir = "team-keys"
    public static let teamKeyExtension = "key"
    /// Phase Track-5 S2 — workspace sub-folder root.
    public static let workspacesSubdir = "workspaces"

    public static let x25519PrivateLength = 32
    public static let teamKeyLength = 32

    /// `~/Library/Application Support/Leaf/keystore/`. Co-located with `db.key` —
    /// the same subdir as `DatabasePath`, a separate sub-folder for team
    /// material (isolation from the SQLCipher key file).
    public static func defaultRoot() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent(DatabasePath.applicationSupportSubdir, isDirectory: true)
            .appendingPathComponent("keystore", isDirectory: true)
    }

    // MARK: - X25519 private (32B per device)

    public static func writeX25519Private(_ bytes: Data, at root: URL = defaultRoot()) throws {
        let url = root.appendingPathComponent(x25519PrivateFilename, isDirectory: false)
        try writeAtomic(bytes, to: url, expectedLength: x25519PrivateLength)
    }

    public static func readX25519Private(at root: URL = defaultRoot()) throws -> Data {
        let url = root.appendingPathComponent(x25519PrivateFilename, isDirectory: false)
        return try readExisting(at: url, expectedLength: x25519PrivateLength)
    }

    /// Test/dev only — recursive removeItem on `<root>/`.
    public static func deleteAll(at root: URL = defaultRoot()) throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - TeamKey (workspace-scoped, Phase Track-5 S2)

    /// Write workspace-scoped teamKey to
    /// `<root>/workspaces/<workspaceID>/team-keys/<keyID>.key`.
    /// 0o600 permissions + FileVault discipline. Atomic write.
    public static func writeTeamKey(
        _ bytes: Data,
        workspaceID: String,
        keyID: String,
        at root: URL = defaultRoot()
    ) throws {
        let url = workspaceTeamKeyURL(workspaceID: workspaceID, keyID: keyID, root: root)
        try writeAtomic(bytes, to: url, expectedLength: teamKeyLength)
    }

    public static func readTeamKey(
        workspaceID: String,
        keyID: String,
        at root: URL = defaultRoot()
    ) throws -> Data {
        let url = workspaceTeamKeyURL(workspaceID: workspaceID, keyID: keyID, root: root)
        return try readExisting(at: url, expectedLength: teamKeyLength)
    }

    /// Recursively delete entire workspace directory. Used by hard-wipe (S8)
    /// + test cleanup. NOT used by markLeft (which preserves data).
    public static func deleteWorkspace(workspaceID: String, at root: URL = defaultRoot()) throws {
        let url = workspaceDirectoryURL(workspaceID: workspaceID, root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw LeafError.keyFileUnavailable(reason: error.localizedDescription)
        }
    }

    /// Migrate legacy single-workspace teamKey files
    /// (`<root>/team-keys/<id>.key`) → workspace sub-folder
    /// (`<root>/workspaces/<workspaceID>/team-keys/<id>.key`). Idempotent —
    /// if files already at new location, no-op. Best-effort — silent on
    /// missing legacy dir. Called once by M019 application path.
    public static func relocateLegacyTeamKeys(
        toWorkspaceID workspaceID: String,
        at root: URL = defaultRoot()
    ) throws {
        let legacyDir = root.appendingPathComponent(teamKeysSubdir, isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacyDir.path) else {
            return  // No legacy dir — fresh install OR already relocated.
        }
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: legacyDir,
                includingPropertiesForKeys: nil
            )
        } catch {
            return  // Inaccessible — caller treats as no-op.
        }

        for legacyFile in contents where legacyFile.pathExtension == teamKeyExtension {
            let keyID = legacyFile.deletingPathExtension().lastPathComponent
            let newURL = workspaceTeamKeyURL(workspaceID: workspaceID, keyID: keyID, root: root)
            try ensureParentDirectory(for: newURL)
            if FileManager.default.fileExists(atPath: newURL.path) {
                // Idempotent path — new file already exists. Remove legacy.
                try? FileManager.default.removeItem(at: legacyFile)
                continue
            }
            do {
                try FileManager.default.moveItem(at: legacyFile, to: newURL)
            } catch {
                throw LeafError.keyFileUnavailable(reason: error.localizedDescription)
            }
            // Re-apply 0o600 on moved file (mv preserves but be explicit).
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: newURL.path
            )
        }

        // Cleanup empty legacy dir.
        let remaining = (try? FileManager.default.contentsOfDirectory(
            at: legacyDir,
            includingPropertiesForKeys: nil
        )) ?? []
        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: legacyDir)
        }
    }

    // MARK: - Internals

    private static func workspaceDirectoryURL(workspaceID: String, root: URL) -> URL {
        root
            .appendingPathComponent(workspacesSubdir, isDirectory: true)
            .appendingPathComponent(workspaceID, isDirectory: true)
    }

    private static func workspaceTeamKeyURL(workspaceID: String, keyID: String, root: URL) -> URL {
        workspaceDirectoryURL(workspaceID: workspaceID, root: root)
            .appendingPathComponent(teamKeysSubdir, isDirectory: true)
            .appendingPathComponent("\(keyID).\(teamKeyExtension)", isDirectory: false)
    }

    private static func ensureParentDirectory(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw LeafError.keyFileUnavailable(reason: error.localizedDescription)
        }
    }

    private static func writeAtomic(_ data: Data, to url: URL, expectedLength: Int) throws {
        guard data.count == expectedLength else {
            throw LeafError.invalidPayload
        }
        try ensureParentDirectory(for: url)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw LeafError.keyFileUnavailable(reason: error.localizedDescription)
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path
            )
        } catch {
            throw LeafError.keyFileUnavailable(reason: error.localizedDescription)
        }
    }

    private static func readExisting(at url: URL, expectedLength: Int) throws -> Data {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LeafError.keyFileUnavailable(reason: error.localizedDescription)
        }
        guard data.count == expectedLength else {
            throw LeafError.keyFileCorrupted
        }
        return data
    }
}
