import Foundation
import Security

/// Stores the 32-byte SQLCipher key in `~/Library/Application Support/Leaf/db.key`
/// (mode 0600). Phase 3.4.5 replaced `KeychainKeyStore` for the main path — keychain
/// access group sharing requires a Developer ID Provisioning Profile, which is not
/// available on distribution. The file-based approach gives native sharing between
/// app/agent/mcp without entitlement infrastructure.
///
/// Protection: file permissions 0600 + FileVault. Sensitivity is comparable to the DB
/// file itself (`events.sqlite` alongside it).
///
/// Migration: on first launch, if the file is absent but the Keychain holds a legacy
/// item from the alpha.2 main app, read it from there and write it to the file
/// (`fetchOrCreate`). Cleanup of the legacy Keychain item is a separate best-effort
/// call from the main app's eager init.
///
/// Concurrency: atomic write (`Data.write` with `.atomic` → POSIX `rename(2)`) + read-back
/// verification. Fully race-free serialization is ensured by the eager call in
/// `LeafApp.init()` before `agent.register()` — it materializes the file before any
/// helper starts.
public enum FileKeyStore {
    public static let keyLengthBytes = 32
    public static let filename = "db.key"

    /// `~/Library/Application Support/Leaf/db.key`. Co-located with `events.sqlite` —
    /// the same subdir as `DatabasePath`.
    public static func defaultURL() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent(DatabasePath.applicationSupportSubdir, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    /// Idempotent. Returns the existing key or creates a new one / migrates from Keychain.
    public static func fetchOrCreate(at url: URL = defaultURL()) throws -> Data {
        try ensureParentDirectory(for: url)

        if FileManager.default.fileExists(atPath: url.path) {
            return try readExisting(at: url)
        }

        // Bridge migration: the alpha.2 main app may have placed the key in the default
        // Keychain group ("" → per-bundle group `tech.gundem.leaf`). Helpers' own group is empty.
        let legacy: Data?
        do {
            legacy = try KeychainKeyStore.fetchOnly()
        } catch {
            legacy = nil  // Keychain unavailable / locked / denied — fall through to generate.
        }

        let candidate: Data
        if let legacy = legacy, legacy.count == keyLengthBytes {
            candidate = legacy
        } else {
            candidate = try generateRandomKey()
        }

        try writeAtomic(candidate, to: url)
        return try readBackAndVerify(candidate: candidate, at: url)
    }

    /// Deletes the file. Test/dev tearDown.
    public static func delete(at url: URL = defaultURL()) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Best-effort cleanup of the legacy Keychain item. Called by the main app ONCE
    /// after a successful `fetchOrCreate` — helpers do not do this (their Keychain group
    /// differs, the item isn't there anyway). Swallow errors: errSecItemNotFound is normal.
    public static func cleanupLegacyKeychainBestEffort() {
        try? KeychainKeyStore.delete(accessGroup: "")
    }

    // MARK: - Internals

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

    private static func readExisting(at url: URL) throws -> Data {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LeafError.keyFileUnavailable(reason: error.localizedDescription)
        }
        guard data.count == keyLengthBytes else {
            throw LeafError.keyFileCorrupted
        }
        return data
    }

    private static func writeAtomic(_ data: Data, to url: URL) throws {
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

    private static func readBackAndVerify(candidate: Data, at url: URL) throws -> Data {
        // Read-back closes the "two processes both write" race: last-writer wins,
        // both processes return the actual on-disk bytes.
        let onDisk: Data
        do {
            onDisk = try Data(contentsOf: url)
        } catch {
            throw LeafError.keyFileUnavailable(reason: error.localizedDescription)
        }
        guard onDisk.count == keyLengthBytes else {
            throw LeafError.keyFileCorrupted
        }
        return onDisk
    }

    private static func generateRandomKey() throws -> Data {
        var bytes = Data(count: keyLengthBytes)
        let status = bytes.withUnsafeMutableBytes { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, keyLengthBytes, base)
        }
        guard status == errSecSuccess else {
            throw LeafError.keychainUnavailable(status)  // CSPRNG also via Security framework
        }
        return bytes
    }
}
