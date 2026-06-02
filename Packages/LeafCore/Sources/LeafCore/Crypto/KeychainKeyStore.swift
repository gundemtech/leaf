import Foundation
import Security

/// **DEPRECATED — kept for one-shot migration to FileKeyStore (Phase 3.4.5).**
/// Remove together with `LeafError.keychainUnavailable` in Phase 3.5+ after
/// confirmed stable runtime for alpha users.
///
/// Previously generated a 32-byte random key for SQLCipher and stored it in the macOS Keychain.
///
/// - Accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — accessible
///   after the session's first unlock, not synced to iCloud.
/// - Access group: shared across app / agent / mcp (`$(TeamID).tech.gundem.leaf`).
///   All three processes read the same key → a single DB.
///
/// Phase 3.4.5 replaced this with `FileKeyStore` — keychain access group sharing
/// requires a Developer ID Provisioning Profile, which is not present on distribution.
/// `fetchOnly` remains for bridge migration into FileKeyStore (legacy alpha.2 users).
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

    /// Fetch-only without auto-create. Returns `nil` if `errSecItemNotFound`.
    /// Used by `FileKeyStore.fetchOrCreate` for bridge migration —
    /// the alpha.2 main app wrote the key into the default Keychain group, Phase 3.4.5
    /// moves it to `~/Library/Application Support/Leaf/db.key`.
    public static func fetchOnly(
        accessGroup: String = "",
        service: String = "tech.gundem.leaf",
        account: String = "events.db.key"
    ) throws -> Data? {
        return try fetch(accessGroup: accessGroup, service: service, account: account)
    }

    /// Deletes the key. For dev reset / test tearDown.
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
            // Phase 3.5 — silent migration: if the Keychain is locked / authorization is required,
            // return errSecInteractionNotAllowed without a UI prompt instead of a modal for the user.
            // SecItemAdd ignores this parameter; fetch/delete get a silent fail.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        // Access group applies only to signed binaries (with the matching entitlement).
        // In unit tests (unsigned) we leave it empty — the Keychain operates in the default keychain.
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
