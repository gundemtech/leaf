import CryptoKit
import Foundation

/// Phase AI Coworker P5 (v1.5) — value types for **client-side attestation** of
/// the verifiable (GPU-TEE) inference path. The client verifies the operator's
/// attestation locally and fails closed before sending the prompt; these types
/// carry the challenge, the parsed report, and the verdict.
///
/// Privacy: a verdict NEVER carries prompt or event content, and NEVER the raw
/// expected measurement — only per-check booleans + the assurance level + the
/// transport key the request must be pinned to.

/// A freshness challenge. Tinfoil's current flow does not echo a client nonce
/// (its liveness rests on the TLS-key binding); the nonce is kept for vendors that
/// support a challenge and as a freshness anchor alongside the report timestamp.
public struct AttestationChallenge: Sendable, Equatable {
  public let nonce: Data
  public let issuedAtMs: Int64
  public let maxAgeMs: Int64

  public init(nonce: Data, issuedAtMs: Int64, maxAgeMs: Int64) {
    self.nonce = nonce
    self.issuedAtMs = issuedAtMs
    self.maxAgeMs = maxAgeMs
  }

  /// 32 crypto-random bytes (CryptoKit) + a freshness window. `nowMs` is injected
  /// for testability.
  public static func random(nowMs: Int64, maxAgeMs: Int64 = 300_000) -> AttestationChallenge {
    let nonce = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    return AttestationChallenge(nonce: nonce, issuedAtMs: nowMs, maxAgeMs: maxAgeMs)
  }
}

/// How much the client actually verified. **`.full` is never produced in P5** —
/// the PoC verifier checks measurement-vs-pinned, signature-vs-injected-root,
/// freshness, and TLS-SPKI binding, but defers the full VCEK→AMD cert-chain walk
/// and the Sigstore transparency-log inclusion proof. Honest-claim discipline
/// (§8.5): the product must not say "verifiable" while assurance is `.poc`.
public enum AttestationAssurance: String, Sendable, Equatable {
  case poc
  case full
}

/// The outcome of a verification. Content-free by construction.
public struct AttestationVerdict: Sendable, Equatable {
  public let isVerified: Bool
  public let assurance: AttestationAssurance
  /// The attested+connection-bound transport SPKI the request MUST be pinned to.
  /// `nil` on failure.
  public let boundPublicKeySPKI: Data?
  public let measurementMatched: Bool
  public let freshnessOK: Bool
  public let signatureOK: Bool
  public let spkiBindingOK: Bool

  public init(
    isVerified: Bool, assurance: AttestationAssurance, boundPublicKeySPKI: Data?,
    measurementMatched: Bool, freshnessOK: Bool, signatureOK: Bool, spkiBindingOK: Bool
  ) {
    self.isVerified = isVerified
    self.assurance = assurance
    self.boundPublicKeySPKI = boundPublicKeySPKI
    self.measurementMatched = measurementMatched
    self.freshnessOK = freshnessOK
    self.signatureOK = signatureOK
    self.spkiBindingOK = spkiBindingOK
  }

  /// The safe default: a refusal. Used by the no-op substrate and as the audited
  /// verdict when verification throws.
  public static let failClosed = AttestationVerdict(
    isVerified: false, assurance: .poc, boundPublicKeySPKI: nil,
    measurementMatched: false, freshnessOK: false, signatureOK: false, spkiBindingOK: false)
}

/// Typed errors for the attestation path (per-integration error type, cf.
/// `SummarizerError`). Messages are opaque — never interpolate report bytes.
///
/// Only INFRA failures are thrown (no verdict can be formed). Per-check outcomes
/// (signature/measurement/freshness/SPKI) are reported as booleans on
/// `AttestationVerdict`, not thrown — so the summarizer can over-record the
/// unverified verdict before refusing.
public enum AttestationError: Error, Equatable, Sendable {
  case fetchFailed(String)
  case malformedDocument
  case unavailable
}

/// The raw attestation document plus the SPKI captured from the live TLS
/// connection it was fetched over (the binding anchor).
public struct FetchedAttestation: Sendable, Equatable {
  public let rawDocument: Data
  public let connectionSPKI: Data
  public init(rawDocument: Data, connectionSPKI: Data) {
    self.rawDocument = rawDocument
    self.connectionSPKI = connectionSPKI
  }
}

/// Normalized view of an attestation document. The vendor-specific bytes are
/// converted into this shape by an `AttestationDocumentParser`, so the verifier
/// core is independent of any one operator's wire format.
public struct ParsedAttestation: Sendable, Equatable {
  public let measurement: Data
  public let attestedKeySPKI: Data
  public let signature: Data
  /// The exact byte region the `signature` covers (verified against the root key).
  public let signedRegion: Data
  public let issuedAtMs: Int64
  /// Echoed challenge nonce, when the operator supports it (Tinfoil: nil).
  public let echoedNonce: Data?

  public init(
    measurement: Data, attestedKeySPKI: Data, signature: Data, signedRegion: Data,
    issuedAtMs: Int64, echoedNonce: Data?
  ) {
    self.measurement = measurement
    self.attestedKeySPKI = attestedKeySPKI
    self.signature = signature
    self.signedRegion = signedRegion
    self.issuedAtMs = issuedAtMs
    self.echoedNonce = echoedNonce
  }
}
