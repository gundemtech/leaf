import Foundation
import Security

/// **DEPRECATED — kept for one-shot migration to FileKeyStore (Phase 3.4.5).**
/// Удалить вместе с `LeafError.keychainUnavailable` в Phase 3.5+ после
/// confirmed stable runtime у alpha-юзеров.
///
/// Раньше генерил 32-byte random key для SQLCipher и хранил его в macOS Keychain.
///
/// - Accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — доступ
///   после первого unlock'а сессии, не синкается на iCloud.
/// - Access group: shared между app / agent / mcp (`$(TeamID).tech.gundem.leaf`).
///   Все три процесса читали один и тот же ключ → единая DB.
///
/// Phase 3.4.5 заменил это на `FileKeyStore` — keychain access group sharing
/// требует Developer ID Provisioning Profile, которого нет на distribution.
/// `fetchOnly` остаётся для bridge migration в FileKeyStore (legacy alpha.2 пользователи).
public enum KeychainKeyStore {
    public static let keyLengthBytes = 32

    /// Fetch existing key or generate+store new one.
    public static func fetchOrCreate(
        accessGroup: String,
        service: String = "tech.gundem.leaf",
        account: String = "events.db.key"
    ) throws -> Data {
        if let existing = try fetch(accessGroup: accessGroup, service: service, account: account) {
            return existing
        }

        let newKey = try generateRandomKey()
        try insert(key: newKey, accessGroup: accessGroup, service: service, account: account)
        return newKey
    }

    /// Fetch-only без auto-create. Возвращает `nil` если `errSecItemNotFound`.
    /// Используется `FileKeyStore.fetchOrCreate` для bridge migration —
    /// alpha.2 main app записал ключ в default Keychain group, Phase 3.4.5
    /// переносит его в `~/Library/Application Support/Leaf/db.key`.
    public static func fetchOnly(
        accessGroup: String = "",
        service: String = "tech.gundem.leaf",
        account: String = "events.db.key"
    ) throws -> Data? {
        return try fetch(accessGroup: accessGroup, service: service, account: account)
    }

    /// Удаляет ключ. Для dev reset / тестового tearDown.
    public static func delete(
        accessGroup: String,
        service: String = "tech.gundem.leaf",
        account: String = "events.db.key"
    ) throws {
        var query = baseQuery(accessGroup: accessGroup, service: service, account: account)
        query[kSecAttrAccount as String] = account

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LeafError.keychainUnavailable(status)
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
                throw LeafError.keychainUnavailable(errSecInternalError)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw LeafError.keychainUnavailable(status)
        }
    }

    private static func insert(key: Data, accessGroup: String, service: String, account: String) throws {
        var attributes = baseQuery(accessGroup: accessGroup, service: service, account: account)
        attributes[kSecValueData as String] = key
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw LeafError.keychainUnavailable(status)
        }
    }

    private static func baseQuery(accessGroup: String, service: String, account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Phase 3.5 — silent migration: если Keychain locked / нужна authorization,
            // вернём errSecInteractionNotAllowed без UI prompt вместо modal у юзера.
            // SecItemAdd параметр игнорирует, fetch/delete получают тихий fail.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
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
            throw LeafError.keychainUnavailable(status)
        }
        return bytes
    }
}
