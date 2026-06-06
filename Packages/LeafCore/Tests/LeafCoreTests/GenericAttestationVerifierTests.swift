import CryptoKit
import XCTest

@testable import LeafCore

/// P5 — the load-bearing verify-before-send core, exercised over SYNTHETIC vectors
/// (Ed25519-signed JSON; the real SEV-SNP/Sigstore format + ECDSA-P384 + VCEK chain
/// are deferred — see SimpleAttestationDocumentParser). Verdict is returned with
/// per-check booleans (throws only on infra: fetch/parse); the summarizer gates on
/// isVerified, so failure = no send.
final class GenericAttestationVerifierTests: XCTestCase {
  private struct StubFetcher: AttestationFetcher {
    let doc: Data
    let connectionSPKI: Data
    var fetchError: AttestationError?
    func fetch(challenge: AttestationChallenge) async throws -> FetchedAttestation {
      if let e = fetchError { throw e }
      return FetchedAttestation(rawDocument: doc, connectionSPKI: connectionSPKI)
    }
  }

  private let rootKey = Curve25519.Signing.PrivateKey()
  private let measurement = Data("MEASUREMENT-EXPECTED".utf8)
  private let attestedKey = Data("ATTESTED-TLS-SPKI".utf8)
  private let issuedAt: Int64 = 1_000_000

  /// Builds a synthetic doc signed by `signWith` over the canonical region.
  private func signedDoc(
    measurement m: Data? = nil, attestedKey k: Data? = nil, issuedAtMs: Int64? = nil,
    echoedNonce: Data? = nil, signWith: Curve25519.Signing.PrivateKey? = nil,
    corruptSignature: Bool = false
  ) -> Data {
    let meas = m ?? measurement
    let key = k ?? attestedKey
    let ts = issuedAtMs ?? issuedAt
    let region = SimpleAttestationDocumentParser.canonicalSignedRegion(
      measurement: meas, attestedKeySPKI: key, issuedAtMs: ts, echoedNonce: echoedNonce)
    var sig = (try? (signWith ?? rootKey).signature(for: region)) ?? Data()
    if corruptSignature, !sig.isEmpty { sig[0] ^= 0xFF }
    var fields = [
      "\"measurement\":\"\(meas.base64EncodedString())\"",
      "\"attested_key_spki\":\"\(key.base64EncodedString())\"",
      "\"signature\":\"\(sig.base64EncodedString())\"",
      "\"issued_at_ms\":\(ts)",
    ]
    if let n = echoedNonce { fields.append("\"echoed_nonce\":\"\(n.base64EncodedString())\"") }
    return Data("{\(fields.joined(separator: ","))}".utf8)
  }

  private func verifier(
    doc: Data, connectionSPKI: Data? = nil, pinned: Data? = nil, root: Data? = nil,
    nowMs: Int64? = nil, fetchError: AttestationError? = nil
  ) -> GenericAttestationVerifier {
    let fixedNow = nowMs ?? issuedAt  // local capture (no non-Sendable self in the closure)
    return GenericAttestationVerifier(
      fetcher: StubFetcher(
        doc: doc, connectionSPKI: connectionSPKI ?? attestedKey, fetchError: fetchError),
      parser: SimpleAttestationDocumentParser(),
      pinnedMeasurement: pinned ?? measurement,
      trustRootPublicKey: root ?? rootKey.publicKey.rawRepresentation,
      nowMs: { fixedNow })
  }

  func testValidAttestationVerifies() async throws {
    let v = try await verifier(doc: signedDoc()).verify(challenge: .random(nowMs: issuedAt))
    XCTAssertTrue(v.isVerified)
    XCTAssertEqual(v.assurance, .poc)  // never .full in P5
    XCTAssertEqual(v.boundPublicKeySPKI, attestedKey)
    XCTAssertTrue(v.measurementMatched && v.freshnessOK && v.signatureOK && v.spkiBindingOK)
  }

  func testBadSignatureFailsClosed() async throws {
    let v = try await verifier(doc: signedDoc(corruptSignature: true)).verify(
      challenge: .random(nowMs: issuedAt))
    XCTAssertFalse(v.isVerified)
    XCTAssertFalse(v.signatureOK)
    XCTAssertNil(v.boundPublicKeySPKI)
  }

  func testSignatureFromWrongRootFailsClosed() async throws {
    let v = try await verifier(doc: signedDoc(signWith: Curve25519.Signing.PrivateKey())).verify(
      challenge: .random(nowMs: issuedAt))
    XCTAssertFalse(v.isVerified)
    XCTAssertFalse(v.signatureOK)
  }

  func testWrongMeasurementFailsClosed() async throws {
    let v = try await verifier(doc: signedDoc(), pinned: Data("DIFFERENT".utf8)).verify(
      challenge: .random(nowMs: issuedAt))
    XCTAssertFalse(v.isVerified)
    XCTAssertFalse(v.measurementMatched)
  }

  func testStaleAttestationFailsClosed() async throws {
    // now is far past issuedAt + maxAge.
    let v = try await verifier(doc: signedDoc(), nowMs: issuedAt + 10_000_000).verify(
      challenge: AttestationChallenge(nonce: Data(count: 32), issuedAtMs: issuedAt, maxAgeMs: 1_000))
    XCTAssertFalse(v.isVerified)
    XCTAssertFalse(v.freshnessOK)
  }

  func testFutureIssuedAtFailsClosed() async throws {
    let v = try await verifier(doc: signedDoc(), nowMs: issuedAt - 10_000).verify(
      challenge: AttestationChallenge(nonce: Data(count: 32), issuedAtMs: issuedAt, maxAgeMs: 1_000))
    XCTAssertFalse(v.isVerified)
    XCTAssertFalse(v.freshnessOK)
  }

  func testSPKIBindingMismatchFailsClosed() async throws {
    // attestation's attested key ≠ the live connection key → MITM swap blocked.
    let v = try await verifier(doc: signedDoc(), connectionSPKI: Data("OTHER-CONN-KEY".utf8)).verify(
      challenge: .random(nowMs: issuedAt))
    XCTAssertFalse(v.isVerified)
    XCTAssertFalse(v.spkiBindingOK)
    XCTAssertNil(v.boundPublicKeySPKI)
  }

  func testNonceEchoMismatchFailsClosed() async throws {
    // Vendor echoes a nonce that differs from the challenge → freshness fails.
    let challenge = AttestationChallenge(nonce: Data("CHALLENGE-NONCE".utf8), issuedAtMs: issuedAt, maxAgeMs: 300_000)
    let v = try await verifier(doc: signedDoc(echoedNonce: Data("WRONG-NONCE".utf8)),
                               nowMs: issuedAt).verify(challenge: challenge)
    XCTAssertFalse(v.isVerified)
    XCTAssertFalse(v.freshnessOK)
  }

  func testMatchingNonceEchoVerifies() async throws {
    let nonce = Data("CHALLENGE-NONCE".utf8)
    let challenge = AttestationChallenge(nonce: nonce, issuedAtMs: issuedAt, maxAgeMs: 300_000)
    let v = try await verifier(doc: signedDoc(echoedNonce: nonce), nowMs: issuedAt).verify(
      challenge: challenge)
    XCTAssertTrue(v.isVerified)
  }

  func testPlaceholderRootKeyFailsClosed() async throws {
    // H4: garbage/placeholder trust root must not fake-pass — invalid key → signatureOK false.
    let v = try await verifier(doc: signedDoc(), root: Data([0x00, 0x01, 0x02])).verify(
      challenge: .random(nowMs: issuedAt))
    XCTAssertFalse(v.isVerified)
    XCTAssertFalse(v.signatureOK)
  }

  func testFetchErrorPropagates() async {
    do {
      _ = try await verifier(doc: Data(), fetchError: .fetchFailed("transport")).verify(
        challenge: .random(nowMs: issuedAt))
      XCTFail("infra fetch error must throw")
    } catch {
      XCTAssertEqual(error as? AttestationError, .fetchFailed("transport"))
    }
  }

  func testMalformedDocumentThrows() async {
    do {
      _ = try await verifier(doc: Data("not json".utf8)).verify(challenge: .random(nowMs: issuedAt))
      XCTFail("unparseable document must throw")
    } catch {
      XCTAssertEqual(error as? AttestationError, .malformedDocument)
    }
  }

  func testNeverEmitsFullAssurance() async throws {
    // Honest-claim: even a fully-valid attestation stays at .poc in P5.
    let v = try await verifier(doc: signedDoc()).verify(challenge: .random(nowMs: issuedAt))
    XCTAssertNotEqual(v.assurance, .full)
  }
}
