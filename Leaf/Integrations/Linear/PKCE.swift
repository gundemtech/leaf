//
//  PKCE.swift
//  Leaf
//
//  Phase 4.1 — Proof Key for Code Exchange (RFC 7636).
//  Public — public-safe (RFC, not moat).
//

import Foundation
import CryptoKit

nonisolated enum PKCE {
    /// Generates a fresh PKCE pair + state nonce for a single OAuth flow.
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

    /// `count` random bytes → base64url-without-padding string.
    /// Verifier per RFC 7636 §4.1: 43-128 characters, unreserved alphabet.
    /// 32 bytes → 43 base64url chars (lower bound of the range).
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
