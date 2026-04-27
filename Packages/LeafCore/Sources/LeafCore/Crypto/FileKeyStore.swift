import Foundation
import Security

/// Хранит 32-byte SQLCipher key в файле `~/Library/Application Support/Leaf/db.key`
/// (mode 0600). Phase 3.4.5 заменил `KeychainKeyStore` для основного потока — keychain
/// access group sharing требует Developer ID Provisioning Profile, которого нет на
/// distribution. File-based подход даёт нативный sharing между app/agent/mcp без
/// entitlement-инфраструктуры.
///
/// Защита: file permissions 0600 + FileVault. Sensitivity сравнима с самой DB файлом
/// (`events.sqlite` рядом).
///
/// Migration: на первом launch если файла нет, но в Keychain есть legacy item от
/// alpha.2 main app — читаем оттуда и пишем в файл (`fetchOrCreate`). Cleanup legacy
/// Keychain item — отдельный best-effort вызов из main app eager init.
///
/// Concurrency: atomic write (`Data.write` с `.atomic` → POSIX `rename(2)`) + read-back
/// verification. Полную race-free serialization обеспечивает eager call в `LeafApp.init()`
/// до `agent.register()` — он материализует файл до того как любой helper стартанёт.
public enum FileKeyStore {
    public static let keyLengthBytes = 32
    public static let filename = "db.key"

    /// `~/Library/Application Support/Leaf/db.key`. Co-located с `events.sqlite` —
    /// та же subdir что у `DatabasePath`.
    public static func defaultURL() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent(DatabasePath.applicationSupportSubdir, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    /// Idempotent. Returns existing key или создаёт новый/мигрирует с Keychain.
    public static func fetchOrCreate(at url: URL = defaultURL()) throws -> Data {
        try ensureParentDirectory(for: url)

        if FileManager.default.fileExists(atPath: url.path) {
            return try readExisting(at: url)
        }

        // Bridge migration: alpha.2 main app мог положить ключ в default Keychain group
        // ("" → per-bundle group `tech.gundem.leaf`). Helpers свой group — пустой.
        let legacy: Data?
        do {
            legacy = try KeychainKeyStore.fetchOnly()
        } catch {
            legacy = nil  // Keychain unavailable / locked / denied — fall through к generate.
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

    /// Удаляет файл. Test/dev tearDown.
    public static func delete(at url: URL = defaultURL()) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Best-effort cleanup legacy Keychain item. Вызывается main app'ом ОДИН РАЗ
    /// после успешного `fetchOrCreate` — helpers это не делают (их Keychain group
    /// другая, item там и так нет). Swallow errors: errSecItemNotFound нормально.
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
        // Read-back закрывает race "два процесса оба пишут": last-writer wins,
        // оба процесса возвращают на самом деле on-disk bytes.
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
