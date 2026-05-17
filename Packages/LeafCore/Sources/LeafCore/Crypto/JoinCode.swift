import Foundation
import os

/// Phase 5.5.A — human-readable Join code formatter for X25519 32-byte pubkey.
///
/// Wire (76 chars): `XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-YYYY`
/// 8 groups × 8 chars base32-Crockford data (excluding I/L/O/U for human readability),
/// 4-char trailing CRC32-low-20-bits checksum, 8 hyphens between 9 groups.
///
/// Backwards-compat per Phase 5.5 D10: decoder also accepts raw 64-char hex (alpha.9-11
/// invitees may paste old format during transition); no checksum verification on hex path.
public enum JoinCode {

    /// Encode 32-byte X25519 pubkey → 76-char human-readable string.
    /// Throws `.malformed` if input is not exactly 32 bytes.
    public static func encode(pubkey: Data) throws -> String {
        guard pubkey.count == 32 else { throw JoinCodeError.malformed }

        // Step 1 — pad to 40 bytes (40×8 = 320 bits = 64×5 — exact base32 fit).
        var padded = pubkey
        padded.append(contentsOf: [UInt8](repeating: 0, count: 8))

        // Step 2 — base32-Crockford encode 40 bytes → 64 chars exactly.
        let dataChars = Self.base32CrockfordEncode(padded)
        precondition(dataChars.count == 64, "base32 of 40 bytes must be 64 chars")

        // Step 3 — CRC32-IEEE over raw 32-byte pubkey, low 20 bits.
        let crc = Self.crc32IEEE(pubkey) & 0x000F_FFFF

        // Step 4 — encode 20 bits → 4 base32 chars (big-endian 5-bit groups).
        var checksumChars = ""
        for shift in stride(from: 15, through: 0, by: -5) {
            let nibble = Int((crc >> shift) & 0x1F)
            checksumChars.append(Self.alphabet[Self.alphabet.index(Self.alphabet.startIndex, offsetBy: nibble)])
        }
        precondition(checksumChars.count == 4)

        // Step 5 — group 8 chars × 8 + checksum joined by '-'.
        var groups: [String] = []
        let chars = Array(dataChars)
        for i in 0..<8 {
            groups.append(String(chars[i * 8..<(i + 1) * 8]))
        }
        groups.append(checksumChars)
        return groups.joined(separator: "-")
    }

    /// Decode formatted (or legacy hex) string → 32-byte X25519 pubkey.
    public static func decode(_ raw: String) -> Result<Data, JoinCodeError> {
        // Canonicalize: strip whitespace + hyphens, uppercase, typo-fix O→0, I→1, L→1.
        let canonical = Self.canonicalize(raw)

        // Strict path — 68 chars (64 data + 4 checksum), all alphabet.
        if canonical.count == 68, canonical.allSatisfy({ Self.alphabetSet.contains($0) }) {
            return Self.decodeStrict(canonical: canonical)
        }

        // Lenient hex fallback — 64 chars, all hex digits.
        if canonical.count == 64, canonical.allSatisfy({ Self.hexDigits.contains($0) }) {
            if let bytes = Self.hexDecode(canonical), bytes.count == 32 {
                Logger(subsystem: "tech.gundem.leaf.core", category: "join-code")
                    .warning("legacy hex JoinCode accepted (alpha.9-11 compat)")
                return .success(bytes)
            }
        }

        return .failure(.malformed)
    }

    // MARK: - Private constants

    private static let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    private static let alphabetSet: Set<Character> = Set(alphabet)
    private static let hexDigits: Set<Character> = Set("0123456789ABCDEF")

    // MARK: - Private — canonicalize

    private static func canonicalize(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            // Skip ASCII whitespace.
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" { continue }
            if scalar == "-" { continue }
            // Uppercase ASCII.
            let upper = String(scalar).uppercased()
            // Crockford typo-fixes.
            switch upper {
            case "O": out.append("0")
            case "I", "L": out.append("1")
            default: out.append(upper)
            }
        }
        return out
    }

    // MARK: - Private — strict decode

    private static func decodeStrict(canonical: String) -> Result<Data, JoinCodeError> {
        let chars = Array(canonical)
        let dataChars = String(chars[0..<64])
        let checksumChars = String(chars[64..<68])

        guard let padded = base32CrockfordDecode(dataChars), padded.count == 40 else {
            return .failure(.malformed)
        }
        // Last 8 bytes must be zero (per encode pad invariant).
        guard padded[32..<40].allSatisfy({ $0 == 0 }) else {
            return .failure(.malformed)
        }
        let pubkey = Data(padded[0..<32])

        // Recompute checksum and compare.
        let expectedCRC = crc32IEEE(pubkey) & 0x000F_FFFF
        var expectedChars = ""
        for shift in stride(from: 15, through: 0, by: -5) {
            let nibble = Int((expectedCRC >> shift) & 0x1F)
            expectedChars.append(alphabet[alphabet.index(alphabet.startIndex, offsetBy: nibble)])
        }

        guard expectedChars == checksumChars else { return .failure(.checksumMismatch) }
        return .success(pubkey)
    }

    // MARK: - Private — base32-Crockford codec

    private static func base32CrockfordEncode(_ bytes: Data) -> String {
        var out = ""
        out.reserveCapacity((bytes.count * 8 + 4) / 5)

        var buffer: UInt32 = 0
        var bitsInBuffer = 0
        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte)
            bitsInBuffer += 8
            while bitsInBuffer >= 5 {
                bitsInBuffer -= 5
                let idx = Int((buffer >> bitsInBuffer) & 0x1F)
                out.append(alphabet[alphabet.index(alphabet.startIndex, offsetBy: idx)])
            }
        }
        if bitsInBuffer > 0 {
            let idx = Int((buffer << (5 - bitsInBuffer)) & 0x1F)
            out.append(alphabet[alphabet.index(alphabet.startIndex, offsetBy: idx)])
        }
        return out
    }

    private static func base32CrockfordDecode(_ s: String) -> [UInt8]? {
        // Build reverse lookup once per call (32 entries — cheap).
        var lookup = [Character: UInt8](minimumCapacity: 32)
        for (idx, ch) in alphabet.enumerated() { lookup[ch] = UInt8(idx) }

        var out: [UInt8] = []
        out.reserveCapacity((s.count * 5) / 8)

        var buffer: UInt32 = 0
        var bitsInBuffer = 0
        for ch in s {
            guard let val = lookup[ch] else { return nil }
            buffer = (buffer << 5) | UInt32(val)
            bitsInBuffer += 5
            if bitsInBuffer >= 8 {
                bitsInBuffer -= 8
                out.append(UInt8((buffer >> bitsInBuffer) & 0xFF))
            }
        }
        return out
    }

    // MARK: - Private — CRC32-IEEE (poly 0xEDB88320, init 0xFFFFFFFF, output XOR 0xFFFFFFFF)

    private static func crc32IEEE(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask: UInt32 = (crc & 1 != 0) ? 0xEDB8_8320 : 0
                crc = (crc >> 1) ^ mask
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - Private — hex decode (lenient path)

    private static func hexDecode(_ s: String) -> Data? {
        guard s.count % 2 == 0 else { return nil }
        var out = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let byte = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        return out
    }
}

public enum JoinCodeError: Error, Sendable, Equatable {
    case malformed
    case checksumMismatch
}
