import Foundation

/// P5 — sink for the attestation reverse-audit trail. Records the OUTCOME of a
/// verify-before-send attempt (verdict booleans + assurance + non-secret endpoint
/// label + the user-side summary), NEVER prompt/event content and NEVER the raw
/// pinned measurement. Injected so `AttestedSummarizer` is unit-testable with a spy.
///
/// The concrete DB sink + its `llm_attestation_audit` table are **deferred** to the
/// production-wiring phase (the attested path is not yet runtime-reachable, so the
/// table would have zero rows — a speculative permanent migration). This protocol +
/// entry exist now to prove the audit-first discipline in `AttestedSummarizer`.
public protocol AttestationAuditSink: Sendable {
  func record(_ entry: AttestationAuditEntry) async throws
}

/// Substrate sink — records nothing (the concrete DB sink is deferred to the
/// production-wiring phase). Safe because the attested path is not runtime-wired in
/// P5; the production wiring MUST supply a persisting sink before the path goes live.
public struct NoOpAttestationAuditSink: AttestationAuditSink {
  public init() {}
  public func record(_ entry: AttestationAuditEntry) async throws {}
}

/// One attestation audit row. STRUCTURALLY content-free + measurement-free — there
/// is no field that can hold prompt text, event bodies, or the raw expected
/// measurement (only the boolean `measurementMatched`).
public struct AttestationAuditEntry: Sendable, Equatable {
  public let occurredAtMs: Int64
  public let path: String  // InferencePath.auditLabel ("attested")
  public let model: String  // resolved SummarizerModel.rawValue
  public let verified: Bool
  public let assurance: String  // AttestationAssurance.rawValue ("poc")
  public let measurementMatched: Bool
  public let freshnessOK: Bool
  public let signatureOK: Bool
  public let spkiBindingOK: Bool
  public let endpointLabel: String  // non-secret operator label (e.g. "tinfoil-poc")
  public let sourceSummary: String  // counts/kinds, never bodies

  public init(
    occurredAtMs: Int64, path: String, model: String, verified: Bool, assurance: String,
    measurementMatched: Bool, freshnessOK: Bool, signatureOK: Bool, spkiBindingOK: Bool,
    endpointLabel: String, sourceSummary: String
  ) {
    self.occurredAtMs = occurredAtMs
    self.path = path
    self.model = model
    self.verified = verified
    self.assurance = assurance
    self.measurementMatched = measurementMatched
    self.freshnessOK = freshnessOK
    self.signatureOK = signatureOK
    self.spkiBindingOK = spkiBindingOK
    self.endpointLabel = endpointLabel
    self.sourceSummary = sourceSummary
  }

  /// Build a row from a verdict — copies only the booleans + assurance (never the
  /// bound SPKI bytes, never any content).
  public init(
    occurredAtMs: Int64, path: String, model: String, endpointLabel: String,
    sourceSummary: String, verdict: AttestationVerdict
  ) {
    self.init(
      occurredAtMs: occurredAtMs, path: path, model: model, verified: verdict.isVerified,
      assurance: verdict.assurance.rawValue, measurementMatched: verdict.measurementMatched,
      freshnessOK: verdict.freshnessOK, signatureOK: verdict.signatureOK,
      spkiBindingOK: verdict.spkiBindingOK, endpointLabel: endpointLabel,
      sourceSummary: sourceSummary)
  }
}
