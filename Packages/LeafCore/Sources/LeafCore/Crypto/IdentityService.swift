import CryptoKit
import Foundation

/// Phase 5.2.A — idempotent X25519 long-term identity bootstrap.
/// Reads `<root>/x25519.priv` if exists (32B), иначе генерирует
/// `Curve25519.KeyAgreement.PrivateKey()` + atomically writes through
/// `TeamKeystore.writeX25519Private`. Mirror enum-namespace style of
/// `TeamKeystore` (5.1.D).
///
/// Single source of truth для long-term identity bootstrap по обе стороны
/// invite handshake (admin `OrgService.createPersonalOrg` + invitee
/// accept-invite path в 5.2.E). Replaces 5.1.D inline
/// `randomX25519PrivateKey` factory в `OrgService` (commit 4 этой phase).
public enum IdentityService {

    /// Read existing 32B X25519 priv из `<root>/x25519.priv` если файл есть;
    /// иначе генерирует новую keypair и atomically пишет.
    /// - Throws:
    ///   - `LeafError.keyFileCorrupted` — файл существует, но размер ≠ 32B
    ///     (propagates, не silent regenerate — invariant: corrupted state
    ///     stays observable).
    ///   - `LeafError.keyFileUnavailable(reason:)` — write failed
    ///     (filesystem / permissions).
    public static func ensureLocalIdentity(
        at root: URL = TeamKeystore.defaultRoot()
    ) throws -> Curve25519.KeyAgreement.PrivateKey {
        return try ensureLocalIdentity(at: root, generate: {
            Curve25519.KeyAgreement.PrivateKey()
        })
    }

    /// Test/dev overload — inject deterministic keypair generator. Используется
    /// только на gen-path (когда файл отсутствует). Если файл уже на диске,
    /// generator НЕ вызывается (см. `IdentityServiceTests.testInjectedGenerator_…`).
    public static func ensureLocalIdentity(
        at root: URL,
        generate: @Sendable () -> Curve25519.KeyAgreement.PrivateKey
    ) throws -> Curve25519.KeyAgreement.PrivateKey {
        // Read path: existing 32B file → reconstruct PrivateKey.
        do {
            let bytes = try TeamKeystore.readX25519Private(at: root)
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes)
        } catch LeafError.keyFileUnavailable {
            // File missing — fall through to gen path.
        }
        // .keyFileCorrupted / Curve25519 init throws propagate (not caught).

        // Gen path: generate + atomically persist.
        let priv = generate()
        try TeamKeystore.writeX25519Private(priv.rawRepresentation, at: root)
        return priv
    }
}
