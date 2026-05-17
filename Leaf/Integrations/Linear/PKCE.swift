//
//  PKCE.swift
//  Leaf
//
//  Phase 4.1 — Proof Key for Code Exchange (RFC 7636).
//  Public — public-safe (RFC, не moat).
//

import CryptoKit
import Foundation

nonisolated enum PKCE {
    /// Generates a fresh PKCE pair + state nonce для одного OAuth flow.
    /// `verifier` — 32 random bytes → base64url; `challenge` — SHA-256(verifier) → base64url.
    static func makeChallenge() -> Challenge {
        let verifier = randomBase64URL(byteCount: 32)
        let challengeData = Data(SHA256.hash(data: Data(verifier.utf8)))
        let challenge = base64URL(challengeData)
        let state = randomBase64URL(byteCount: 32)
        return Challenge(verifier: verifier, challenge: challenge, state: state)
    }

    struct Challenge: Sendable {
        let verifier: String
        let challenge: String
        let state: String
    }

    // MARK: - Helpers

    /// `count` random bytes → base64url-without-padding строка.
    /// Verifier по RFC 7636 §4.1: 43-128 символов, unreserved alphabet.
    /// 32 bytes → 43 base64url chars (нижняя граница диапазона).
    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return base64URL(Data(bytes))
    }

    /// Standard base64 → URL-safe variant (RFC 4648 §5): `+→-`, `/→_`, drop padding `=`.
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
