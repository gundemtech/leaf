import Foundation

/// Phase 5.5.A — `leaf://invite/<token>#<otp>` deep-link composer/parser.
///
/// - scheme: `leaf` (registered in Info.plist `CFBundleURLTypes` in Phase 5.5.B).
/// - host: `invite` (per-action discriminator; `leaf://join`, `leaf://present` reserved).
/// - path: `/<token>` where token = 32-char base64url (per 5.2.D `InviteToken.value`).
/// - fragment: `<otp>` = 6 ASCII digits. Browser strips fragment from HTTP referers
///   so the OTP doesn't leak to server logs if the URL ends up on a webpage.
public enum InviteURL {

    /// Compose. `token` and `otp` are pass-through — no validation here; callers
    /// originate them from `RelayClient.postInvite` (token) and `OTP.generate6`
    /// (otp), already in canonical alphabets.
    public static func compose(token: String, otp: String) -> URL {
        var components = URLComponents()
        components.scheme = "leaf"
        components.host = "invite"
        components.path = "/" + token
        components.fragment = otp
        return components.url!
    }

    /// Strict parser. Any deviation from the locked format returns `.malformed`.
    public static func parse(_ url: URL) -> Result<(token: String, otp: String), InviteURLError> {
        guard url.scheme?.lowercased() == "leaf" else { return .failure(.malformed) }
        guard url.host?.lowercased() == "invite" else { return .failure(.malformed) }

        // Path must be exactly "/{token}", no extra components.
        let path = url.path
        guard path.hasPrefix("/") else { return .failure(.malformed) }
        let token = String(path.dropFirst())
        guard !token.isEmpty else { return .failure(.malformed) }
        guard token.count == 32 else { return .failure(.malformed) }
        guard token.allSatisfy({ Self.base64URLChars.contains($0) }) else {
            return .failure(.malformed)
        }
        // No nested slash: token should not itself contain '/'.
        if token.contains("/") { return .failure(.malformed) }

        // Query must be empty (we never compose with one).
        if let q = url.query, !q.isEmpty { return .failure(.malformed) }

        // Fragment must be exactly 6 ASCII digits.
        guard let otp = url.fragment, !otp.isEmpty else { return .failure(.malformed) }
        guard otp.count == 6 else { return .failure(.malformed) }
        guard otp.allSatisfy({ Self.asciiDigits.contains($0) }) else {
            return .failure(.malformed)
        }

        return .success((token: token, otp: otp))
    }

    private static let base64URLChars: Set<Character> = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )
    private static let asciiDigits: Set<Character> = Set("0123456789")
}

public enum InviteURLError: Error, Sendable, Equatable {
    case malformed
}
