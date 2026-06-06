import XCTest

@testable import LeafCore

/// P5 — the verifier seam + its fail-closed substrate. Mirrors
/// `ModelGateSubstrateTests` / the NoOpSummarizer pattern.
final class AttestationVerifierSubstrateTests: XCTestCase {
  private let challenge = AttestationChallenge.random(nowMs: 0)

  func testNoOpVerifierAlwaysFailsClosed() async {
    do {
      _ = try await NoOpAttestationVerifier().verify(challenge: challenge)
      XCTFail("the no-op substrate must refuse (fail-closed)")
    } catch {
      XCTAssertEqual(error as? AttestationError, .unavailable)
    }
  }

  func testMoatSubstrateIsTheFailClosedNoOp() async {
    do {
      _ = try await AttestationVerifierMoat.publicSubstrate.verifier.verify(challenge: challenge)
      XCTFail("substrate must never verify")
    } catch {
      XCTAssertEqual(error as? AttestationError, .unavailable)
    }
  }

  func testFakeVerifierProvesSeamInjectable() async throws {
    struct FakeVerifier: AttestationVerifier {
      func verify(challenge: AttestationChallenge) async throws -> AttestationVerdict {
        AttestationVerdict(
          isVerified: true, assurance: .poc, boundPublicKeySPKI: Data([1]),
          measurementMatched: true, freshnessOK: true, signatureOK: true, spkiBindingOK: true)
      }
    }
    let v = try await AttestationVerifierMoat(verifier: FakeVerifier()).verifier.verify(
      challenge: challenge)
    XCTAssertTrue(v.isVerified)
    XCTAssertEqual(v.assurance, .poc)
  }
}
