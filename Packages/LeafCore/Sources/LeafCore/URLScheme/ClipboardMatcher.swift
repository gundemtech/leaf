import Foundation

/// Phase 5.5.B — scan free-form clipboard text for a `leaf://invite/...` URL OR a formatted/legacy JoinCode.
/// Priority: InviteURL (the more specific signal — token+OTP exchange) is tried first; on a miss
/// the JoinCode is scanned as a fallback (admin-side wants the invitee pubkey).
public enum ClipboardMatcher {

    public enum Match: Sendable, Equatable {
        case inviteURL(URL)
        case joinCode(Data)
        case none
    }

    public static func match(_ raw: String) -> Match {
        // 1. Try InviteURL — find the first occurrence of the `leaf://invite/...` substring.
        if let url = scanInviteURL(in: raw) {
            return .inviteURL(url)
        }
        // 2. Try JoinCode — format + lenient hex. The sliding window over token candidates
        //    is chosen as follows: split on whitespace + trim trailing punctuation.
        if let bytes = scanJoinCode(in: raw) {
            return .joinCode(bytes)
        }
        return .none
    }

    // MARK: - Private — InviteURL scan

    private static func scanInviteURL(in raw: String) -> URL? {
        // Find substring starting "leaf://invite/" — take until first whitespace / punctuation that
        // isn't valid in URL fragment. A simple scan instead of regex for control over the allowed
        // alphabet. After extracting candidate substring, attempt InviteURL.parse — the strict validator
        // filters out malformed extras (extra path / query string / wrong OTP shape).
        let needle = "leaf://invite/"
        guard let startIdx = raw.range(of: needle)?.lowerBound else { return nil }
        var endIdx = raw.endIndex
        for idx in raw.indices[startIdx...] {
            let ch = raw[idx]
            if ch.isWhitespace || ch == "\"" || ch == "'" || ch == "<" || ch == ">" || ch == "}" || ch == ")" {
                endIdx = idx
                break
            }
        }
        // Trim trailing punctuation `.`, `,`, `!`, `?`, `;` if any.
        var slice = raw[startIdx..<endIdx]
        let trailingPunct: Set<Character> = [".", ",", "!", "?", ";"]
        while let last = slice.last, trailingPunct.contains(last) {
            slice = slice.dropLast()
        }
        guard let candidate = URL(string: String(slice)) else { return nil }
        if case .success = InviteURL.parse(candidate) {
            return candidate
        }
        return nil
    }

    // MARK: - Private — JoinCode scan

    private static func scanJoinCode(in raw: String) -> Data? {
        // Strategy: split on whitespace, attempt decode for each token; ALSO try
        // glued pairs of adjacent tokens in case the chat wrapped the JoinCode with a line break.
        // JoinCode.decode canonicalizes whitespace+hyphens itself, but we need the split so we don't decode
        // the whole message (it would pass canonicalize and just happen to match the length by chance).
        let tokens = raw.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        for token in tokens {
            if case .success(let bytes) = JoinCode.decode(token) { return bytes }
        }
        return nil
    }
}
