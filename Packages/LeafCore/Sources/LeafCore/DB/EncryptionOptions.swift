import Foundation

/// Source of the 32-byte key for SQLCipher. In dev/unit tests we use
/// `.data(...)` with a deterministic pattern; in production — `.callback { ... }`
/// wrapped around `KeychainKeyStore.fetchOrCreate`.
public enum KeyProvider: Sendable {
    case data(Data)
    case callback(@Sendable () throws -> Data)

    public func resolve() throws -> Data {
        switch self {
        case .data(let d): return d
        case .callback(let cb): return try cb()
        }
    }
}

/// A named `PRAGMA name = value` pair. The specific names/values are
/// moat (`LeafCorePrivate.ProdConfigs`), not in the public repo.
public struct SQLCipherPragma: Sendable, Hashable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Passed to `Database.openForWrite/openForRead` to enable SQLCipher.
/// `nil` encryption on open* calls means plaintext — that's CI/unit tests.
/// At production call-sites (Agent/App/MCP) — always `.some(...)`.
public struct EncryptionOptions: Sendable {
    /// Key (raw 32 bytes). Will be injected as `PRAGMA key = x'HEX'`,
    /// without PBKDF2 (architectural requirement — see architecture.md).
    public let keyProvider: KeyProvider

    /// PRAGMAs applied BEFORE `PRAGMA key`. Example: pragmas affecting the
    /// header layout must be pre-key, otherwise SQLCipher won't accept them.
    public let preKeyPragmas: [SQLCipherPragma]

    /// PRAGMAs applied AFTER `PRAGMA key`. Any cipher_* tuning pragmas
    /// that don't affect the header or the key format.
    public let postKeyPragmas: [SQLCipherPragma]

    public init(
        keyProvider: KeyProvider,
        preKeyPragmas: [SQLCipherPragma] = [],
        postKeyPragmas: [SQLCipherPragma] = []
    ) {
        self.keyProvider = keyProvider
        self.preKeyPragmas = preKeyPragmas
        self.postKeyPragmas = postKeyPragmas
    }
}
