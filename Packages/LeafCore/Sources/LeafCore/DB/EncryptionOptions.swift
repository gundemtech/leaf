import Foundation

/// Источник 32-byte ключа для SQLCipher. В dev/unit-тестах используем
/// `.data(...)` с детерминированным pattern; в проде — `.callback { ... }`
/// обёрнутый вокруг `KeychainKeyStore.fetchOrCreate`.
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

/// Именованная пара `PRAGMA name = value`. Конкретные имена/значения —
/// moat (`LeafCorePrivate.ProdConfigs`), не в публичном репо.
public struct SQLCipherPragma: Sendable, Hashable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Передаётся в `Database.openForWrite/openForRead` для включения SQLCipher.
/// `nil` encryption на вызовах open* означает plaintext — это CI/unit-тесты.
/// В продовых call-sites (Agent/App/MCP) — всегда `.some(...)`.
public struct EncryptionOptions: Sendable {
    /// Ключ (raw 32 байта). Будет инжектирован как `PRAGMA key = x'HEX'`,
    /// без PBKDF2 (архитектурное требование — see architecture.md).
    public let keyProvider: KeyProvider

    /// PRAGMA'ы, применяемые ДО `PRAGMA key`. Пример: pragmas влияющие на
    /// header layout должны быть pre-key иначе SQLCipher их не примет.
    public let preKeyPragmas: [SQLCipherPragma]

    /// PRAGMA'ы, применяемые ПОСЛЕ `PRAGMA key`. Любые cipher_* tuning-pragmas
    /// которые не влияют на header или формат ключа.
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
