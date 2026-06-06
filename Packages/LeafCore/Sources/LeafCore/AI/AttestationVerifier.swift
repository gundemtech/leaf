import Foundation

/// Fetches the operator's raw attestation document AND records the SPKI of the
/// live TLS connection it was fetched over (the binding anchor). Injectable so the
/// verifier core is testable without a network.
public protocol AttestationFetcher: Sendable {
  func fetch(challenge: AttestationChallenge) async throws -> FetchedAttestation
}

/// Verifies an operator's attestation locally. **Fail-closed:** any failure throws
/// `AttestationError`; success returns a verdict with `isVerified == true`. The
/// prompt is sent only after a verified verdict (see `AttestedSummarizer`).
public protocol AttestationVerifier: Sendable {
  func verify(challenge: AttestationChallenge) async throws -> AttestationVerdict
}

/// Injection seam for the prod verifier (mirrors `AISummarizerMoat` /
/// `ModelGateMoat`). The pinned trust VALUES (expected measurement, root key,
/// endpoint) live in `LeafCorePrivate`; the algorithm is public.
public struct AttestationVerifierMoat: Sendable {
  public let verifier: any AttestationVerifier
  public init(verifier: any AttestationVerifier) { self.verifier = verifier }
  /// CI/substrate builds get a verifier that always refuses — the attested path
  /// cannot run without the prod moat (no false "verified").
  public static let publicSubstrate = AttestationVerifierMoat(verifier: NoOpAttestationVerifier())
}

/// The safe default: always fails closed (parallels `NoOpSummarizer`). A build
/// without the prod attestation moat can never send a prompt on the attested path.
public struct NoOpAttestationVerifier: AttestationVerifier {
  public init() {}
  public func verify(challenge: AttestationChallenge) async throws -> AttestationVerdict {
    throw AttestationError.unavailable
  }
}
