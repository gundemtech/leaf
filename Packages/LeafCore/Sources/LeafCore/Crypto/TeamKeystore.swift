import Foundation
import Security

/// Phase 5.1.D — file-based key writer/reader для team primitives:
/// X25519 long-term private (per device, contract §7) + per-rotation teamKey
/// файлы (current + history, contract §7 "key lifecycle"). Рядом с `db.key`
/// (FileKeyStore) живут в `~/Library/Application Support/Leaf/keystore/`.
///
/// Защита: file permissions 0o600 + FileVault. Sensitivity сравнима с самой
/// DB файлом (`events.sqlite`).
///
/// Layout:
/// - `<root>/x25519.priv` — 32 bytes raw, single file per device.
/// - `<root>/team-keys/<UUID>.key` — 32 bytes raw, one file per rotation.
///   Filename = `team_keys.id` (UUID lowercase canonical). "Current rotation"
///   определяется через `Database.readActiveTeamKey()` → file lookup by id.
///   No separate "current" pointer — DB-driven, no split-brain risk.
///
/// Concurrency: atomic write (`Data.write` с `.atomic` → POSIX `rename(2)`).
/// Mirror discipline `FileKeyStore`. Write-then-read-back-verify не нужен —
/// 5.1.D writers вызываются только из `OrgService.createPersonalOrg`
/// (single point), не из distributed processes (mirrors KeyStore-for-DB
/// pattern, где race important; team keystore материализуется один раз).
public enum TeamKeystore {
    public static let x25519PrivateFilename = "x25519.priv"
    public static let teamKeysSubdir = "team-keys"
    public static let teamKeyExtension = "key"
    /// Phase Track-5 S2 — workspace sub-folder root.
    public static let workspacesSubdir = "workspaces"

    public static let x25519PrivateLength = 32
    public static let teamKeyLength = 32

    /// `~/Library/Application Support/Leaf/keystore/`. Co-located с `db.key` —
    /// та же subdir что у `DatabasePath`, отдельная sub-folder под team
    /// material (изоляция от SQLCipher key файла).
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

    // MARK: - TeamKey (32B per rotation, named by UUID)

    /// `id` — `team_keys.id` (UUID lowercase canonical). Written to
    /// `<root>/team-keys/<id>.key`.
    public static func writeTeamKey(_ bytes: Data, id: String, at root: URL = defaultRoot()) throws {
        let url = teamKeyURL(id: id, root: root)
        try writeAtomic(bytes, to: url, expectedLength: teamKeyLength)
    }

    public static func readTeamKey(id: String, at root: URL = defaultRoot()) throws -> Data {
        let url = teamKeyURL(id: id, root: root)
        return try readExisting(at: url, expectedLength: teamKeyLength)
    }

    /// Test/dev only — recursive removeItem на `<root>/`.
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

    private static func teamKeyURL(id: String, root: URL) -> URL {
        return root
            .appendingPathComponent(teamKeysSubdir, isDirectory: true)
            .appendingPathComponent("\(id).\(teamKeyExtension)", isDirectory: false)
    }

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
