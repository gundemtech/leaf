import Foundation
import Security

/// Генерит 32-byte random key для SQLCipher и хранит его в macOS Keychain.
///
/// - Accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — доступ
///   после первого unlock'а сессии, не синкается на iCloud.
/// - Access group: shared между app / agent / mcp (`$(TeamID).tech.gundem.leafcontrol`).
///   Все три процесса читают один и тот же ключ → единая DB.
///
/// Phase 1.1 — ключ не используется реально (plaintext SQLite), но infra готова
/// для Phase 1.5 SQLCipher migration.
public enum KeychainKeyStore {
    public static let keyLengthBytes = 32

    /// Fetch existing key or generate+store new one.
    public static func fetchOrCreate(
        accessGroup: String,
        service: String = "tech.gundem.leafcontrol",
        account: String = "events.db.key"
    ) throws -> Data {
        if let existing = try fetch(accessGroup: accessGroup, service: service, account: account) {
            return existing
        }

        let newKey = try generateRandomKey()
        try insert(key: newKey, accessGroup: accessGroup, service: service, account: account)
        return newKey
    }

    /// Удаляет ключ. Для dev reset / тестового tearDown.
    public static func delete(
        accessGroup: String,
        service: String = "tech.gundem.leafcontrol",
        account: String = "events.db.key"
    ) throws {
        var query = baseQuery(accessGroup: accessGroup, service: service, account: account)
        query[kSecAttrAccount as String] = account

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LeafControlError.keychainUnavailable(status)
        }
    }

    // MARK: - Internals

    private static func fetch(accessGroup: String, service: String, account: String) throws -> Data? {
        var query = baseQuery(accessGroup: accessGroup, service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw LeafControlError.keychainUnavailable(errSecInternalError)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw LeafControlError.keychainUnavailable(status)
        }
    }

    private static func insert(key: Data, accessGroup: String, service: String, account: String) throws {
        var attributes = baseQuery(accessGroup: accessGroup, service: service, account: account)
        attributes[kSecValueData as String] = key
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw LeafControlError.keychainUnavailable(status)
        }
    }

    private static func baseQuery(accessGroup: String, service: String, account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Access group применяется только для подписанных бинарей (с подходящим entitlement).
        // В unit-тестах (unsigned) оставляем пустой — Keychain работает в default keychain.
        if !accessGroup.isEmpty {
            q[kSecAttrAccessGroup as String] = accessGroup
        }
        return q
    }

    private static func generateRandomKey() throws -> Data {
        var bytes = Data(count: keyLengthBytes)
        let status = bytes.withUnsafeMutableBytes { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, keyLengthBytes, base)
        }
        guard status == errSecSuccess else {
            throw LeafControlError.keychainUnavailable(status)
        }
        return bytes
    }
}
