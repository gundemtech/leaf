import XCTest

@testable import LeafCore

/// P5 — value types for client-side attestation. No crypto here (that is
/// `GenericAttestationVerifierTests`); this asserts the type contracts +
/// fail-closed default + honest-claim invariant (no `.full` baked into a default).
final class AttestationTypesTests: XCTestCase {
  func testFailClosedVerdictIsRefusal() {
    let v = AttestationVerdict.failClosed
    XCTAssertFalse(v.isVerified)
    XCTAssertNil(v.boundPublicKeySPKI)
    XCTAssertFalse(v.measurementMatched)
    XCTAssertFalse(v.freshnessOK)
    XCTAssertFalse(v.signatureOK)
    XCTAssertFalse(v.spkiBindingOK)
    // Honest-claim: even the failure default sits at PoC assurance — `.full` is
    // never produced anywhere in P5.
    XCTAssertEqual(v.assurance, .poc)
  }

  func testChallengeRandomNonceIsFreshAndLongEnough() {
    let c = AttestationChallenge.random(nowMs: 1_000)
    XCTAssertGreaterThanOrEqual(c.nonce.count, 32)
    XCTAssertEqual(c.issuedAtMs, 1_000)
    XCTAssertGreaterThan(c.maxAgeMs, 0)
    // Two challenges differ (crypto-random nonce, not a counter).
    XCTAssertNotEqual(AttestationChallenge.random(nowMs: 1_000).nonce,
                      AttestationChallenge.random(nowMs: 1_000).nonce)
  }

  func testAttestationErrorEquatable() {
    XCTAssertEqual(AttestationError.malformedDocument, .malformedDocument)
    XCTAssertNotEqual(AttestationError.malformedDocument, .unavailable)
    XCTAssertEqual(AttestationError.fetchFailed("transport"), .fetchFailed("transport"))
    XCTAssertNotEqual(AttestationError.fetchFailed("a"), .fetchFailed("b"))
  }

  func testAssuranceRawValues() {
    XCTAssertEqual(AttestationAssurance.poc.rawValue, "poc")
    XCTAssertEqual(AttestationAssurance.full.rawValue, "full")
  }

  func testParsedAndFetchedAreValueTypes() {
    let parsed = ParsedAttestation(
      measurement: Data([1, 2]), attestedKeySPKI: Data([3]), signature: Data([4]),
      signedRegion: Data([5]), issuedAtMs: 7, echoedNonce: Data([6]))
    XCTAssertEqual(parsed.measurement, Data([1, 2]))
    XCTAssertEqual(parsed.echoedNonce, Data([6]))
    let fetched = FetchedAttestation(rawDocument: Data([9]), connectionSPKI: Data([8]))
    XCTAssertEqual(fetched.connectionSPKI, Data([8]))
  }
}
