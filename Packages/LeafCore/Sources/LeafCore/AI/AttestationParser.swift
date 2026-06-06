import Foundation

/// Converts an operator's raw attestation document into the normalized
/// `ParsedAttestation`, so the verifier core is independent of any vendor's wire
/// format. Injectable for tests.
public protocol AttestationDocumentParser: Sendable {
  func parse(_ raw: Data) throws -> ParsedAttestation
}

/// P5 PoC parser for a **synthetic** JSON envelope. It is NOT the real Tinfoil
/// SEV-SNP + Sigstore binary format — that parser is deferred to the
/// production-wiring phase (and is what would raise assurance above `.poc`). This
/// exists so the verify-before-send pipeline + the canonical-signed-region
/// discipline can be built and tested end-to-end now.
///
/// Document shape (all byte fields base64):
/// `{ "measurement", "attested_key_spki", "signature", "issued_at_ms",
///    "echoed_nonce"? }`
///
/// The `signedRegion` is **computed canonically here** from the fields — it is not
/// read from the document. The verifier defines what must be signed; trusting a
/// document to declare its own signed region would be self-certifying.
public struct SimpleAttestationDocumentParser: AttestationDocumentParser {
  public init() {}

  private struct Envelope: Decodable {
    let measurement: String
    let attested_key_spki: String
    let signature: String
    let issued_at_ms: Int64
    let echoed_nonce: String?
  }

  public func parse(_ raw: Data) throws -> ParsedAttestation {
    let env: Envelope
    do {
      env = try JSONDecoder().decode(Envelope.self, from: raw)
    } catch {
      throw AttestationError.malformedDocument
    }
    guard
      let measurement = Data(base64Encoded: env.measurement),
      let spki = Data(base64Encoded: env.attested_key_spki),
      let signature = Data(base64Encoded: env.signature)
    else { throw AttestationError.malformedDocument }

    var echoedNonce: Data?
    if let n = env.echoed_nonce {
      guard let decoded = Data(base64Encoded: n) else { throw AttestationError.malformedDocument }
      echoedNonce = decoded
    }

    let signedRegion = Self.canonicalSignedRegion(
      measurement: measurement, attestedKeySPKI: spki,
      issuedAtMs: env.issued_at_ms, echoedNonce: echoedNonce)

    return ParsedAttestation(
      measurement: measurement, attestedKeySPKI: spki, signature: signature,
      signedRegion: signedRegion, issuedAtMs: env.issued_at_ms, echoedNonce: echoedNonce)
  }

  /// The canonical bytes the signature must cover: measurement ‖ attested-SPKI ‖
  /// big-endian issued-at ‖ nonce. Deterministic; shared by test-vector builders.
  public static func canonicalSignedRegion(
    measurement: Data, attestedKeySPKI: Data, issuedAtMs: Int64, echoedNonce: Data?
  ) -> Data {
    var region = Data()
    region.append(measurement)
    region.append(attestedKeySPKI)
    var be = issuedAtMs.bigEndian
    withUnsafeBytes(of: &be) { region.append(contentsOf: $0) }
    if let n = echoedNonce { region.append(n) }
    return region
  }
}
