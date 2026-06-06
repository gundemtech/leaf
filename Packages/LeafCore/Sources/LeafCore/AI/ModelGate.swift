import Foundation

/// Which commercial inference path a request runs on. The reachable model set is
/// clamped per path: Opus is BYOK-only (the AI-included path cannot serve it).
/// The *thresholds* that pick a heavier model are policy and live in
/// `LeafCorePrivate`; this enum is public product vocabulary.
public enum InferencePath: Sendable, Equatable {
  case byok        // user's own key — full model set
  case aiIncluded  // inference provided by us — no Opus
  case attested    // P5 (v1.5, opt-in/experimental) — verifiable GPU-TEE, open-weight only

  /// Stable audit/provenance label. Exhaustive on purpose: a new path must pick a
  /// label here (replaces the `== .byok ? "byok" : "ai_included"` ternaries that
  /// silently mislabelled any third path as `ai_included`).
  public var auditLabel: String {
    switch self {
    case .byok: return "byok"
    case .aiIncluded: return "ai_included"
    case .attested: return "attested"
    }
  }
}

/// Selects the model for a request. The substrate impl is Haiku-only; the real
/// selection policy is `ProdModelGate` (moat).
public protocol ModelGate: Sendable {
  /// - Parameter preferred: a caller hint (e.g. the user asked for a heavier
  ///   model). The gate may clamp it — the AI-included path never returns Opus.
  func model(path: InferencePath, preferred: SummarizerModel?) -> SummarizerModel
}

/// Public-substrate gate: always Haiku, and never Opus on the AI-included path.
/// Zero policy — mirrors `NoOpSummarizer`.
public struct DefaultModelGate: ModelGate {
  public init() {}
  public func model(path: InferencePath, preferred: SummarizerModel?) -> SummarizerModel {
    // The verifiable path serves only an open-weight model; Claude is not
    // attestable, so any preference is ignored here.
    if path == .attested { return .attestedOpenWeight }
    let m = preferred ?? .default
    return (path == .aiIncluded && m == .opus) ? .sonnet : m
  }
}

/// Injection seam for the prod gate (mirrors `AISummarizerMoat` / `DetectorMoat`).
public struct ModelGateMoat: Sendable {
  public let gate: any ModelGate
  public init(gate: any ModelGate) { self.gate = gate }
  public static let publicSubstrate = ModelGateMoat(gate: DefaultModelGate())
}
