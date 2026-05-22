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
    XCTAssertEqual(
      s.count, 76, "expected 76 chars (8 groups×8 + 8 hyphens + 4 checksum); got \(s.count): \(s)")

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
    // Replace any '0' → 'O', any '1' → 'L' in the DATA portion only.
    // Indices 0..71 = data chars + hyphens; indices 72..75 = 4-char checksum group.
    // Substituting inside the checksum group would cause .checksumMismatch (not the
    // .malformed typo-correction path) — so we leave indices ≥ 72 untouched.
    var typoed = ""
    var didOSwap = false
    var didISwap = false
    for (idx, ch) in encoded.enumerated() {
      // Only substitute in the data portion (indices 0..71).
      // Indices 72..75 are the 4-char checksum group — leave untouched.
      if idx < 72 {
        switch ch {
        case "0" where !didOSwap:
          typoed.append("O")
          didOSwap = true
        case "1" where !didISwap:
          typoed.append("L")
          didISwap = true
        default: typoed.append(ch)
        }
      } else {
        typoed.append(ch)
      }
    }
    // If the encoded form doesn't contain any '0' or '1' chars in the data portion,
    // this test is a no-op pass. Skip in that case to avoid false positives.
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
    let mixed = String(
      hexUpper.enumerated().map { idx, ch in
        idx % 2 == 0 ? Character(ch.lowercased()) : ch
      })
    let decoded = try JoinCode.decode(mixed).get()
    XCTAssertEqual(decoded, samplePubkey)
  }

  /// Spec §9 anti-Castagnoli mitigation. A uniform CRC32 polynomial substitution
  /// (IEEE → Castagnoli) would not be caught by any roundtrip test, since
  /// encode/decode share the same crc32IEEE helper. This pins a fixed input
  /// to its expected 4-char base32-Crockford checksum so any poly change fails fast.
  func testEncode_PinnedKnownVectorChecksum() throws {
    let encoded = try JoinCode.encode(pubkey: samplePubkey)
    let checksum = String(encoded.split(separator: "-").last ?? "")
    XCTAssertEqual(checksum.count, 4)
    // Pinned: CRC32-IEEE([0x00..0x1F]) low-20 bits, big-endian base32-Crockford.
    XCTAssertEqual(checksum, "CZMA", "JoinCode CRC32 vector mismatch — possible polynomial change")
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

  // MARK: - M027 Invite-token random code generator

  func testGenerateRandom_ProducesExpected19CharShape() throws {
    let code = try JoinCode.generateRandom()
    XCTAssertTrue(code.hasPrefix("LEAF-"))
    XCTAssertEqual(
      code.count, 19, "expected LEAF-XXXX-XXXX-XXXX 19 chars; got \(code.count): \(code)")
    XCTAssertNotNil(
      code.range(
        of:
          #"^LEAF-[ABCDEFGHJKMNPQRSTVWXYZ2-9]{4}-[ABCDEFGHJKMNPQRSTVWXYZ2-9]{4}-[ABCDEFGHJKMNPQRSTVWXYZ2-9]{4}$"#,
        options: .regularExpression),
      "code shape mismatch: \(code)")
  }

  func testGenerateRandom_AlphabetExcludesILOUZeroOne() throws {
    // Sample many codes — none should ever emit an excluded char.
    let excluded: Set<Character> = ["I", "L", "O", "U", "0", "1"]
    for _ in 0..<400 {
      let code = try JoinCode.generateRandom()
      for ch in code where ch != "-" && !code.hasPrefix("\(ch)EAF") {
        if ch == "L" {
          // Allowed only inside "LEAF-" prefix; the regex check above
          // separately ensures alphabet purity outside the prefix.
          continue
        }
        XCTAssertFalse(
          excluded.contains(ch),
          "code \(code) contains excluded char '\(ch)'")
      }
    }
  }

  func testGenerateRandom_ProducesUniqueValues() throws {
    var seen = Set<String>()
    for _ in 0..<400 {
      let code = try JoinCode.generateRandom()
      XCTAssertFalse(seen.contains(code), "duplicate code: \(code)")
      seen.insert(code)
    }
  }

  func testVerifyChecksum_AcceptsFreshlyGeneratedCode() throws {
    for _ in 0..<50 {
      let code = try JoinCode.generateRandom()
      XCTAssertTrue(
        JoinCode.verifyChecksum(code),
        "freshly generated code should verify: \(code)")
    }
  }

  func testVerifyChecksum_RejectsTypoAtLastPosition() throws {
    let code = try JoinCode.generateRandom()
    var chars = Array(code)
    let lastIdx = chars.count - 1
    let cur = chars[lastIdx]
    // Flip to any other valid alphabet char.
    let other = JoinCode.inviteAlphabet.first(where: { $0 != cur })!
    chars[lastIdx] = other
    let typoed = String(chars)
    XCTAssertFalse(
      JoinCode.verifyChecksum(typoed),
      "typo at checksum position should fail verification: \(code) → \(typoed)")
  }

  func testVerifyChecksum_RejectsTypoInRandomBody() throws {
    // Flipping ANY random body char (positions 5..15 in 19-char string, skipping
    // hyphens at 4, 9, 14) should change recomputed checksum → verify fails.
    for _ in 0..<20 {
      let code = try JoinCode.generateRandom()
      var chars = Array(code)
      // Pick position 5 (first char of first 4-group); flip to neighbour in alphabet.
      let cur = chars[5]
      let curIdx = JoinCode.inviteAlphabet.firstIndex(of: cur)!
      let nextIdx = (curIdx + 1) % JoinCode.inviteAlphabet.count
      chars[5] = JoinCode.inviteAlphabet[nextIdx]
      let typoed = String(chars)
      XCTAssertFalse(
        JoinCode.verifyChecksum(typoed),
        "typo at random body should fail verification: \(code) → \(typoed)")
    }
  }

  func testVerifyChecksum_RejectsWrongLength() {
    XCTAssertFalse(JoinCode.verifyChecksum("LEAF-AAAA-BBBB"))  // too short
    XCTAssertFalse(JoinCode.verifyChecksum("LEAF-AAAA-BBBB-CCCC-DDDD"))  // too long
    XCTAssertFalse(JoinCode.verifyChecksum(""))  // empty
  }

  func testVerifyChecksum_RejectsMissingPrefix() {
    XCTAssertFalse(JoinCode.verifyChecksum("XEAF-AAAA-BBBB-CCCC"))
    XCTAssertFalse(JoinCode.verifyChecksum("AAAA-BBBB-CCCC-DDDD"))
  }

  func testVerifyChecksum_RejectsExcludedAlphabet() {
    XCTAssertFalse(
      JoinCode.verifyChecksum("LEAF-AAA1-BBBB-CCCC"),
      "'1' is excluded → reject")
    XCTAssertFalse(
      JoinCode.verifyChecksum("LEAF-LOOK-OUT2-XXXX"),
      "'L'/'O'/'U' excluded → reject")
  }

  // MARK: - format() — live UI formatting

  func testFormat_EmptyInputStaysEmpty() {
    XCTAssertEqual(JoinCode.format(""), "")
  }

  func testFormat_PartialPrefixLeftAsIs() {
    XCTAssertEqual(JoinCode.format("L"), "L")
    XCTAssertEqual(JoinCode.format("LE"), "LE")
    XCTAssertEqual(JoinCode.format("LEA"), "LEA")
    XCTAssertEqual(JoinCode.format("LEAF"), "LEAF")
  }

  func testFormat_LowercaseAutoUppercased() {
    XCTAssertEqual(JoinCode.format("leaf"), "LEAF")
    XCTAssertEqual(JoinCode.format("leaf-a8x7-b3k9-q2n4"), "LEAF-A8X7-B3K9-Q2N4")
  }

  func testFormat_DashesInsertedAfterEvery4PayloadChars() {
    XCTAssertEqual(JoinCode.format("LEAFA"), "LEAF-A")
    XCTAssertEqual(JoinCode.format("LEAFAB"), "LEAF-AB")
    XCTAssertEqual(JoinCode.format("LEAFABCD"), "LEAF-ABCD")
    XCTAssertEqual(JoinCode.format("LEAFABCDE"), "LEAF-ABCD-E")
    XCTAssertEqual(JoinCode.format("LEAFABCDEFGH"), "LEAF-ABCD-EFGH")
    XCTAssertEqual(JoinCode.format("LEAFA8X7B3K9Q2N4"), "LEAF-A8X7-B3K9-Q2N4")
  }

  func testFormat_PreservesExistingDashes() {
    XCTAssertEqual(JoinCode.format("LEAF-A8X7-B3K9-Q2N4"), "LEAF-A8X7-B3K9-Q2N4")
    XCTAssertEqual(JoinCode.format("LEAF-A8X7"), "LEAF-A8X7")
    XCTAssertEqual(JoinCode.format("LEAF-A8X7-B3K9"), "LEAF-A8X7-B3K9")
  }

  func testFormat_DropsCharsOutsideAlphabet() {
    // I / L / O / U / 0 / 1 are excluded from the 30-char invite alphabet.
    XCTAssertEqual(JoinCode.format("LEAFI"), "LEAF", "I dropped")
    XCTAssertEqual(JoinCode.format("LEAFL"), "LEAF", "L dropped")
    XCTAssertEqual(JoinCode.format("LEAFO"), "LEAF", "O dropped")
    XCTAssertEqual(JoinCode.format("LEAFU"), "LEAF", "U dropped")
    XCTAssertEqual(JoinCode.format("LEAF0"), "LEAF", "0 dropped")
    XCTAssertEqual(JoinCode.format("LEAF1"), "LEAF", "1 dropped")
    XCTAssertEqual(JoinCode.format("LEAFAI8B"), "LEAF-A8B", "interior I dropped, rest kept")
  }

  func testFormat_StripsPunctuationAndWhitespace() {
    XCTAssertEqual(JoinCode.format("  LEAF A8X7 B3K9 Q2N4  "), "LEAF-A8X7-B3K9-Q2N4")
    XCTAssertEqual(JoinCode.format("LEAF/A8X7.B3K9_Q2N4"), "LEAF-A8X7-B3K9-Q2N4")
    XCTAssertEqual(JoinCode.format("LEAF\nA8X7\tB3K9\rQ2N4"), "LEAF-A8X7-B3K9-Q2N4")
  }

  func testFormat_CapsTotalAt19Chars() {
    // Long input — only first 12 alphabet chars kept as payload.
    XCTAssertEqual(JoinCode.format("LEAFABCDEFGHJKMNPQ"), "LEAF-ABCD-EFGH-JKMN")
    XCTAssertEqual(JoinCode.format(String(repeating: "A", count: 50)).count, 19)
  }

  func testFormat_AutoPrependsLEAFWhenPayloadPastedAlone() {
    XCTAssertEqual(JoinCode.format("A8X7B3K9Q2N4"), "LEAF-A8X7-B3K9-Q2N4")
    XCTAssertEqual(JoinCode.format("A8X7-B3K9-Q2N4"), "LEAF-A8X7-B3K9-Q2N4")
  }

  func testFormat_AllNullsCollapseToBareLEAF() {
    // Antоn's repro: typing 0's only — all 0/1's dropped, no payload chars,
    // output settles to bare «LEAF» which fails verifyChecksum (length != 19).
    XCTAssertEqual(JoinCode.format("00000000000000000000"), "LEAF")
    XCTAssertFalse(JoinCode.verifyChecksum(JoinCode.format("00000000000000000000")))
  }

  func testFormat_Idempotent() {
    let codes = [
      "",
      "L", "LEAF", "LEAF-",
      "LEAF-A", "LEAF-A8X7",
      "LEAF-A8X7-B3K9-Q2N4",
    ]
    for code in codes {
      let once = JoinCode.format(code)
      let twice = JoinCode.format(once)
      XCTAssertEqual(once, twice, "format() not idempotent for \(code.debugDescription)")
    }
  }

  func testFormat_GeneratedCodeRoundTrips() throws {
    // Live-formatting a freshly generated code must be a no-op (it's already
    // canonical), and verifyChecksum must still pass on it.
    let code = try JoinCode.generateRandom()
    XCTAssertEqual(JoinCode.format(code), code)
    XCTAssertTrue(JoinCode.verifyChecksum(code))
  }
}
