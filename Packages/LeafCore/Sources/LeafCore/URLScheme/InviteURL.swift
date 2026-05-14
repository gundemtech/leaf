import Foundation

/// Track 5 / S3 — `leaf://invite/<token>?w=<workspaceName>&a=<adminPubkeyHex>[#<otp>]`
/// strict format.
///
/// - scheme: `leaf` (registered in Info.plist CFBundleURLTypes)
/// - host: `invite` (per-action discriminator)
/// - path: `/<token>` where token = 22-char base64url-encoded UUID v4
///   (chars `[A-Za-z0-9_-]`; no `=` padding)
/// - query: exactly two items `w` (URL-encoded workspaceName, ≤64 decoded chars)
///   and `a` (64-hex-char admin X25519 pubkey, lowercase)
/// - fragment: optional 6 ASCII digits (only when require_otp=true)
public enum InviteURL {

    public struct Composed: Sendable, Equatable {
        public let url: URL
        public let token: String
        public let workspaceName: String
        public let adminPubkeyHex: String
        public let otp: String?
    }

    public struct Parsed: Sendable, Equatable {
        public let token: String
        public let workspaceName: String
        public let adminPubkeyHex: String
        public let otp: String?
    }

    /// Compose. Inputs are pass-through — no validation here; callers ensure
    /// token/hex/otp shape before calling.
    public static func compose(token: String,
                               workspaceName: String,
                               adminPubkeyHex: String,
                               otp: String?) -> Composed {
        var components = URLComponents()
        components.scheme = "leaf"
        components.host = "invite"
        components.path = "/" + token
        components.queryItems = [
            URLQueryItem(name: "w", value: workspaceName),
            URLQueryItem(name: "a", value: adminPubkeyHex),
        ]
        if let otp { components.fragment = otp }
        return Composed(
            url: components.url!,
            token: token,
            workspaceName: workspaceName,
            adminPubkeyHex: adminPubkeyHex,
            otp: otp
        )
    }

    /// Strict parser. Any deviation = `.malformed`.
    public static func parse(_ url: URL) -> Result<Parsed, InviteURLError> {
        guard url.scheme?.lowercased() == "leaf" else { return .failure(.malformed) }
        guard url.host?.lowercased() == "invite" else { return .failure(.malformed) }

        let path = url.path
        guard path.hasPrefix("/") else { return .failure(.malformed) }
        let token = String(path.dropFirst())
        guard token.count == 22 else { return .failure(.malformed) }
        guard token.allSatisfy({ Self.base64URLChars.contains($0) }) else {
            return .failure(.malformed)
        }
        if token.contains("/") { return .failure(.malformed) }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.malformed)
        }
        guard let items = components.queryItems, items.count == 2 else {
            return .failure(.malformed)
        }
        let names = Set(items.map(\.name))
        guard names == ["w", "a"] else { return .failure(.malformed) }

        let wValue = items.first { $0.name == "w" }?.value ?? ""
        let aValue = items.first { $0.name == "a" }?.value ?? ""
        guard !wValue.isEmpty, wValue.count <= 64 else { return .failure(.malformed) }
        guard aValue.count == 64, aValue.allSatisfy({ Self.lowerHexChars.contains($0) }) else {
            return .failure(.malformed)
        }

        var otp: String? = nil
        if let frag = url.fragment, !frag.isEmpty {
            guard frag.count == 6, frag.allSatisfy({ Self.asciiDigits.contains($0) }) else {
                return .failure(.malformed)
            }
            otp = frag
        }

        return .success(Parsed(
            token: token,
            workspaceName: wValue,
            adminPubkeyHex: aValue,
            otp: otp
        ))
    }

    private static let base64URLChars: Set<Character> = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )
    private static let lowerHexChars: Set<Character> = Set("0123456789abcdef")
    private static let asciiDigits: Set<Character> = Set("0123456789")
}

public enum InviteURLError: Error, Sendable, Equatable {
    case malformed
    case unsupportedVersion
}
