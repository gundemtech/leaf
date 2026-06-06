import CryptoKit
import Foundation

/// P5 — the public, testable verify-before-send core. Given the operator's fetched
/// attestation, it checks (over the normalized `ParsedAttestation`):
///   1. **freshness** — report timestamp within the challenge window (+ nonce echo
///      when the operator supports one; Tinfoil does not);
///   2. **signature** — `signedRegion` verifies against the INJECTED trust-root key;
///   3. **measurement** — constant-time match against the INJECTED pinned value;
///   4. **SPKI binding** — the attested transport key equals the live TLS key.
///
/// Returns a verdict with per-check booleans (throws only on infra errors —
/// fetch/parse — when no verdict can be formed). `isVerified` is the AND of all
/// checks; `boundPublicKeySPKI` is non-nil only when verified. The summarizer gates
/// on `isVerified`, so any failed check means no prompt is sent (fail-closed).
///
/// **Assurance is always `.poc`.** What this does NOT do (deferred, and what would
/// raise assurance to `.full`): walk the VCEK→AMD certificate chain, check the
/// Sigstore Rekor transparency-log inclusion of the measurement, and parse the real
/// vendor binary format (this core trusts an INJECTED root key + pinned measurement,
/// not a chain). `signatureOK` therefore means "verifies against the value we were
/// told to trust", not "rooted in AMD silicon". The PoC uses Ed25519; the real
/// SEV-SNP report is ECDSA-P384 — part of the deferred real-format adapter.
public struct GenericAttestationVerifier: AttestationVerifier {
  let fetcher: any AttestationFetcher
  let parser: any AttestationDocumentParser
  let pinnedMeasurement: Data
  let trustRootPublicKey: Data
  let nowMs: @Sendable () -> Int64

  public init(
    fetcher: any AttestationFetcher,
    parser: any AttestationDocumentParser,
    pinnedMeasurement: Data,
    trustRootPublicKey: Data,
    nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
  ) {
    self.fetcher = fetcher
    self.parser = parser
    self.pinnedMeasurement = pinnedMeasurement
    self.trustRootPublicKey = trustRootPublicKey
    self.nowMs = nowMs
  }

  public func verify(challenge: AttestationChallenge) async throws -> AttestationVerdict {
    let fetched = try await fetcher.fetch(challenge: challenge)  // throws .fetchFailed
    let parsed = try parser.parse(fetched.rawDocument)           // throws .malformedDocument

    let age = nowMs() - parsed.issuedAtMs
    var freshnessOK = age >= 0 && age <= challenge.maxAgeMs
    if let echoed = parsed.echoedNonce {
      freshnessOK = freshnessOK && Self.constantTimeEqual(echoed, challenge.nonce)
    }

    let signatureOK = Self.verifySignature(
      parsed.signature, over: parsed.signedRegion, rootKey: trustRootPublicKey)
    let measurementMatched = Self.constantTimeEqual(parsed.measurement, pinnedMeasurement)
    let spkiBindingOK = Self.constantTimeEqual(parsed.attestedKeySPKI, fetched.connectionSPKI)

    let isVerified = freshnessOK && signatureOK && measurementMatched && spkiBindingOK
    return AttestationVerdict(
      isVerified: isVerified,
      assurance: .poc,
      boundPublicKeySPKI: isVerified ? fetched.connectionSPKI : nil,
      measurementMatched: measurementMatched,
      freshnessOK: freshnessOK,
      signatureOK: signatureOK,
      spkiBindingOK: spkiBindingOK)
  }

  /// Ed25519 verification against the injected root (PoC). An invalid/placeholder
  /// root key cannot construct a public key → returns false (fail-closed, H4).
  static func verifySignature(_ signature: Data, over region: Data, rootKey: Data) -> Bool {
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rootKey) else {
      return false
    }
    return key.isValidSignature(signature, for: region)
  }

  /// Constant-time byte compare. The length-inequality short-circuit leaks only
  /// length (standard); the value comparison is data-independent.
  static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    let ab = [UInt8](a)
    let bb = [UInt8](b)
    guard ab.count == bb.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
    return diff == 0
  }
}
