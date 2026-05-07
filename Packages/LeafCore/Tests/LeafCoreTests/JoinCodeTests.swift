// Phase 5.5.A — JoinCode encode/decode (32-byte X25519 pubkey ↔ formatted base32-Crockford
// with CRC32 checksum + lenient legacy-hex fallback).

import XCTest
@testable import LeafCore

final class JoinCodeTests: XCTestCase {

    // Deterministic 32-byte fixture (alpha.9-11 invitee shape).
    private let samplePubkey = Data((0..<32).map { UInt8($0) })

    // MARK: - Encode

    func testEncodeDecode_RoundTripsRandomPubkey() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { bytes[i] = UInt8.random(in: 0...255) }
        let pubkey = Data(bytes)

        let encoded = try JoinCode.encode(pubkey: pubkey)
        let decoded = try JoinCode.decode(encoded).get()
        XCTAssertEqual(decoded, pubkey)
    }

    func testEncode_ProducesExpected76CharShape() throws {
        let s = try JoinCode.encode(pubkey: samplePubkey)
        XCTAssertEqual(s.count, 76, "expected 76 chars (8 groups×8 + 8 hyphens + 4 checksum); got \(s.count): \(s)")

        // Hyphen positions: 8, 17, 26, 35, 44, 53, 62, 71 (0-indexed).
        let expectedHyphens: Set<Int> = [8, 17, 26, 35, 44, 53, 62, 71]
        let actualHyphens: Set<Int> = Set(
            s.indices.enumerated().compactMap { idx, i in s[i] == "-" ? idx : nil }
        )
        XCTAssertEqual(actualHyphens, expectedHyphens)

        // Each group only base32-Crockford alphabet [0-9A-Z minus I,L,O,U].
        let alphabet: Set<Character> = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        for ch in s where ch != "-" {
            XCTAssertTrue(alphabet.contains(ch), "non-alphabet char in output: \(ch)")
        }
    }

    func testEncode_ThrowsForNon32ByteInput() {
        for badCount in [0, 1, 31, 33, 64] {
            XCTAssertThrowsError(try JoinCode.encode(pubkey: Data(count: badCount))) { err in
                XCTAssertEqual(err as? JoinCodeError, .malformed)
            }
        }
    }

    func testDecode_RejectsEmptyAndGarbage() {
        for input in ["", "abc", "XXXX-YYYY", "this is not a join code at all 12345"] {
            switch JoinCode.decode(input) {
            case .success: XCTFail("expected failure for input: \(input)")
            case .failure(let err): XCTAssertEqual(err, .malformed)
            }
        }
    }

    // MARK: - Decode lenient + edge

    func testDecode_AcceptsMixedCaseAndExtraHyphens() throws {
        let encoded = try JoinCode.encode(pubkey: samplePubkey)
        // Insert noise: lowercase + extra hyphens + leading/trailing whitespace.
        let noisy = "  " + encoded.lowercased().replacingOccurrences(of: "-", with: "--") + "  "
        let decoded = try JoinCode.decode(noisy).get()
        XCTAssertEqual(decoded, samplePubkey)
    }

    func testDecode_TypoResiliencyOIL1() throws {
        let encoded = try JoinCode.encode(pubkey: samplePubkey)
        // Replace any '0' → 'O', any '1' → 'I' (or 'L' alternation) in DATA portion.
        // Encoded chars are uppercase from alphabet (no 0→O or 1→I tampering issue
        // unless the actual chars '0' or '1' appear). We force-substitute on the raw
        // string to simulate user typo input.
        var typoed = ""
        var didOSwap = false
        var didISwap = false
        for ch in encoded {
            switch ch {
            case "0" where !didOSwap: typoed.append("O"); didOSwap = true
            case "1" where !didISwap: typoed.append("L"); didISwap = true   // L→1 fix path
            default: typoed.append(ch)
            }
        }
        // If the encoded form doesn't contain any '0' or '1' chars, this test is
        // a no-op pass. Skip in that case to avoid false positives.
        guard didOSwap || didISwap else {
            try XCTSkipIf(true, "no 0/1 chars in encoded sample to typo-substitute")
            return
        }
        let decoded = try JoinCode.decode(typoed).get()
        XCTAssertEqual(decoded, samplePubkey)
    }

    func testDecode_ChecksumMismatchOnByteFlip() throws {
        let encoded = try JoinCode.encode(pubkey: samplePubkey)
        // Flip one DATA char (not in last 4-char checksum group).
        // Find first DATA char (index 0) and substitute with another alphabet char.
        var chars = Array(encoded)
        let original = chars[0]
        let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
        let replacement: Character = (original == "0") ? "1" : "0"
        chars[0] = replacement
        let tampered = String(chars)
        // Sanity: tampered must still be in alphabet.
        XCTAssertTrue(alphabet.contains(replacement))

        switch JoinCode.decode(tampered) {
        case .success: XCTFail("expected checksumMismatch")
        case .failure(let err): XCTAssertEqual(err, .checksumMismatch)
        }
    }

    func testDecode_PaddingTamperRejected() throws {
        // Construct a 76-char string where the last 4 data chars (positions 64-67
        // counting only data chars) carry NON-zero in the padding bytes. The strict
        // decoder verifies last 8 bytes == 0 and rejects on any other.
        // Cheapest construction: encode a 32-byte pubkey, then replace last data char
        // (just before checksum) — this corrupts both the padding-zero invariant AND
        // the checksum, so we just check that the FIRST failing branch
        // (padding != 0) returns .malformed (not .checksumMismatch).
        let encoded = try JoinCode.encode(pubkey: samplePubkey)
        var chars = Array(encoded)
        // chars[70] is the 8th data group's last char (index in groups: 8th × 8 = 64,
        // hyphens at 8,17,...,71 — so data char 63 (last data) lives at string index 70).
        XCTAssertNotEqual(chars[70], "-")
        // Force a non-'0' alphabet char that places non-zero bits in the padding tail.
        chars[70] = (chars[70] == "Z") ? "A" : "Z"
        let tampered = String(chars)

        switch JoinCode.decode(tampered) {
        case .success: XCTFail("expected malformed (padding tamper)")
        case .failure(let err): XCTAssertEqual(err, .malformed)
        }
    }

    func testDecode_LegacyHexAccepted() throws {
        // Mixed case hex form (legacy alpha.9-11 invitee paste path).
        let hexUpper = samplePubkey.map { String(format: "%02X", $0) }.joined()
        let mixed = String(hexUpper.enumerated().map { idx, ch in
            idx % 2 == 0 ? Character(ch.lowercased()) : ch
        })
        let decoded = try JoinCode.decode(mixed).get()
        XCTAssertEqual(decoded, samplePubkey)
    }

    func testDecode_LegacyHexWrongLengthRejected() {
        let hex = samplePubkey.map { String(format: "%02x", $0) }.joined()
        // 63 chars (truncated) — neither strict (68) nor hex (64).
        let short = String(hex.dropLast())
        switch JoinCode.decode(short) {
        case .success: XCTFail("expected malformed")
        case .failure(let err): XCTAssertEqual(err, .malformed)
        }
        // 65 chars — also rejected.
        let long = hex + "0"
        switch JoinCode.decode(long) {
        case .success: XCTFail("expected malformed")
        case .failure(let err): XCTAssertEqual(err, .malformed)
        }
    }
}
