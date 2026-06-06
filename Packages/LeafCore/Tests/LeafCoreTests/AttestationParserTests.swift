import XCTest

@testable import LeafCore

/// P5 — the PoC document parser. This parses a SYNTHETIC JSON format, NOT the real
/// Tinfoil SEV-SNP + Sigstore binary format (deferred to the production-wiring
/// phase). It proves the seam + the canonical-signed-region discipline.
final class AttestationParserTests: XCTestCase {
  private let parser = SimpleAttestationDocumentParser()

  private func doc(
    measurement: Data = Data([0xAA, 0xBB]),
    spki: Data = Data([0x01, 0x02, 0x03]),
    signature: Data = Data([0xFF]),
    issuedAtMs: Int64 = 42,
    nonceB64: String?? = .some(nil)  // .some(nil)=field present-but-omitted; .none=present
  ) -> Data {
    var fields = [
      "\"measurement\":\"\(measurement.base64EncodedString())\"",
      "\"attested_key_spki\":\"\(spki.base64EncodedString())\"",
      "\"signature\":\"\(signature.base64EncodedString())\"",
      "\"issued_at_ms\":\(issuedAtMs)",
    ]
    if case let .some(n?) = nonceB64 { fields.append("\"echoed_nonce\":\"\(n)\"") }
    return Data("{\(fields.joined(separator: ","))}".utf8)
  }

  func testParsesValidDocument() throws {
    let parsed = try parser.parse(doc())
    XCTAssertEqual(parsed.measurement, Data([0xAA, 0xBB]))
    XCTAssertEqual(parsed.attestedKeySPKI, Data([0x01, 0x02, 0x03]))
    XCTAssertEqual(parsed.signature, Data([0xFF]))
    XCTAssertEqual(parsed.issuedAtMs, 42)
    XCTAssertNil(parsed.echoedNonce)
  }

  func testParsesEchoedNonceWhenPresent() throws {
    let n = Data([0x09, 0x09]).base64EncodedString()
    let parsed = try parser.parse(doc(nonceB64: .some(n)))
    XCTAssertEqual(parsed.echoedNonce, Data([0x09, 0x09]))
  }

  // Honesty: the signed region is computed canonically by the parser from the
  // fields — it is NOT trusted from the document (the verifier defines what must
  // be signed). Same inputs → same region; any field change → different region.
  func testSignedRegionIsCanonicalNotDocumentProvided() throws {
    let a = try parser.parse(doc(measurement: Data([1])))
    let b = try parser.parse(doc(measurement: Data([2])))
    XCTAssertNotEqual(a.signedRegion, b.signedRegion)
    let a2 = try parser.parse(doc(measurement: Data([1])))
    XCTAssertEqual(a.signedRegion, a2.signedRegion)
    // The region binds the attested key + timestamp too.
    XCTAssertNotEqual(
      try parser.parse(doc(spki: Data([1]))).signedRegion,
      try parser.parse(doc(spki: Data([2]))).signedRegion)
    XCTAssertNotEqual(
      try parser.parse(doc(issuedAtMs: 1)).signedRegion,
      try parser.parse(doc(issuedAtMs: 2)).signedRegion)
  }

  func testMalformedJSONThrows() {
    XCTAssertThrowsError(try parser.parse(Data("not json".utf8))) {
      XCTAssertEqual($0 as? AttestationError, .malformedDocument)
    }
  }

  func testMissingRequiredFieldThrows() {
    let noSig = Data("{\"measurement\":\"AA==\",\"attested_key_spki\":\"AA==\",\"issued_at_ms\":1}".utf8)
    XCTAssertThrowsError(try parser.parse(noSig)) {
      XCTAssertEqual($0 as? AttestationError, .malformedDocument)
    }
  }

  func testBadBase64Throws() {
    let bad = Data("{\"measurement\":\"@@@@\",\"attested_key_spki\":\"AA==\",\"signature\":\"AA==\",\"issued_at_ms\":1}".utf8)
    XCTAssertThrowsError(try parser.parse(bad)) {
      XCTAssertEqual($0 as? AttestationError, .malformedDocument)
    }
  }
}
