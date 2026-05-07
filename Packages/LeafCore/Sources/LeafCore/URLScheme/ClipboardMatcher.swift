import Foundation

/// Phase 5.5.B — scan free-form clipboard text для `leaf://invite/...` URL ИЛИ formatted/legacy JoinCode.
/// Priority: InviteURL (более специфичный signal — token+OTP exchange) попробуется первой; на miss
/// — JoinCode сканируется как fallback (admin-side хочет invitee pubkey).
public enum ClipboardMatcher {

    public enum Match: Sendable, Equatable {
        case inviteURL(URL)
        case joinCode(Data)
        case none
    }

    public static func match(_ raw: String) -> Match {
        // 1. Try InviteURL — найти первое вхождение `leaf://invite/...` substring.
        if let url = scanInviteURL(in: raw) {
            return .inviteURL(url)
        }
        // 2. Try JoinCode — формат + lenient hex. Скользящее окно по token candidates
        //    выбирается так: split по whitespace + хвостовая пунктуация trim'ится.
        if let bytes = scanJoinCode(in: raw) {
            return .joinCode(bytes)
        }
        return .none
    }

    // MARK: - Private — InviteURL scan

    private static func scanInviteURL(in raw: String) -> URL? {
        // Find substring starting "leaf://invite/" — take until first whitespace / punctuation that
        // isn't valid in URL fragment. Простое сканирование вместо regex для контроля над allowed
        // alphabet. After extracting candidate substring, attempt InviteURL.parse — strict validator
        // отфильтрует malformed extras (extra path / query string / wrong OTP shape).
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
        // Стратегия: split по whitespace, попробовать decode для каждого token-а; ALSO попробовать
        // склеенные пары соседних токенов на случай если чат обернул JoinCode переводом строки.
        // JoinCode.decode сам канонизирует whitespace+hyphens, но split нам нужен чтобы не decode'ить
        // целое сообщение (пройдёт canonicalize и чисто случайно длина совпадёт).
        let tokens = raw.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        for token in tokens {
            if case .success(let bytes) = JoinCode.decode(token) { return bytes }
        }
        return nil
    }
}
