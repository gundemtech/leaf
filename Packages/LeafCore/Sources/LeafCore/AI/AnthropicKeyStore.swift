import Foundation
import Security

/// Storage for the user's BYOK Anthropic API key.
public protocol AnthropicKeyStore: Sendable {
  /// Returns the stored key, or nil if not configured.
  func loadKey() throws -> String?
  func storeKey(_ key: String) throws
  func deleteKey() throws
}

/// Keychain-backed BYOK key store. The Anthropic key is a **user credential**,
/// so the Keychain (not `FileKeyStore`, which exists for a multi-process
/// symmetric DB key) is the HIG/security-correct home:
/// - `kSecClassGenericPassword`
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — survives screen lock
///   (a background agent may need it in P1) but never leaves the device
/// - `kSecAttrSynchronizable = false` — never iCloud
/// - no access group in P0 (single-process; multi-process is a P1 decision —
///   prefer IPC-to-the-key-holder over a shared key)
///
/// The key value is never logged. `URLSession.leafEphemeral()` (used by the
/// prod summarizer) keeps the key and responses out of any disk cache.
public struct KeychainAnthropicKeyStore: AnthropicKeyStore {
  private let service: String
  private let account: String

  public init(
    service: String = "tech.gundem.leaf.anthropic",
    account: String = "byok.api.key"
  ) {
    self.service = service
    self.account = account
  }

  public func loadKey() throws -> String? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
        throw LeafError.keychainUnavailable(errSecInternalError)
      }
      return key
    case errSecItemNotFound:
      return nil
    default:
      throw LeafError.keychainUnavailable(status)
    }
  }

  public func storeKey(_ key: String) throws {
    try deleteKey()  // upsert
    var attributes = baseQuery()
    attributes[kSecValueData as String] = Data(key.utf8)
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    attributes[kSecAttrSynchronizable as String] = false

    let status = SecItemAdd(attributes as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw LeafError.keychainUnavailable(status)
    }
  }

  public func deleteKey() throws {
    let status = SecItemDelete(baseQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw LeafError.keychainUnavailable(status)
    }
  }

  private func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      // Silent fail (no modal) if the Keychain is locked / authorization required.
      kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
    ]
  }
}
