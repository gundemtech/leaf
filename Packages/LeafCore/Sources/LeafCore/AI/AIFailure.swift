import Foundation

/// AI-UI-4 — typed user-facing AI failure. Replaces the string-only failure
/// payloads so views key the "Open Settings" CTA off the failure *kind*
/// instead of exact-matching the missing-key message text (which broke the
/// moment messages became path-aware).
public struct AIFailure: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// BYOK path with no key configured.
    case missingKey
    /// Credential rejected (BYOK key revoked / relay rejected the session).
    case auth
    /// Team pool exhausted (relay 402) — the valve out is the user's own key.
    case budget
    case rateLimited
    /// P5 verify-before-send failed; nothing was sent.
    case attestation
    /// Audit-first write failed → the LLM call was aborted (fail-closed).
    case auditWrite
    /// Local gather/DB read failed before any egress.
    case localRead
    /// Catch-all for network/server/decode — retry is the only remedy.
    case transient
  }

  public let kind: Kind
  public let message: String

  public init(kind: Kind, message: String) {
    self.kind = kind
    self.message = message
  }

  /// Which failures earn the "Open Settings" CTA: both are fixed in
  /// Settings → AI Answers (add a key / add your own key past the pool).
  public var showsSettingsCTA: Bool { kind == .missingKey || kind == .budget }
}
