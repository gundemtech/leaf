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

    public static let x25519PrivateLength = 32
    public static let teamKeyLength = 32

    /// `~/Library/Application Support/Leaf/keystore/`. Co-located с `db.key` —
    /// та же subdir что у `DatabasePath`, отдельная sub-folder под team
    /// material (изоляция от SQLCipher key файла).
    public static func defaultRoot() -> URL {
        let support =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return
            support
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

    // MARK: - Internals

    private static func teamKeyURL(id: String, root: URL) -> URL {
                    root
            .appendingPathComponent(teamKeysSubdir, isDirectory: true)
            .appendingPathComponent("\(id).\(teamKeyExtension)", isDirectory: false)
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
