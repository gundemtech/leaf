import Foundation

/// Supplies the bearer credential for the AI-included inference path. The
/// concrete adapter (reading the Supabase session) is wired by the LLM-path
/// composition root in P1 — it owns the live session source; P0b ships the seam
/// + a test fake only.
public protocol AIInferenceAuthTokenProvider: Sendable {
  /// Returns a FRESH access token. The implementation MUST refresh a
  /// near-expiry session (`SupabaseClient.ensureFreshSession()`, not the cached
  /// `currentSession()`) and MUST throw when no session exists — an empty
  /// bearer is never acceptable.
  func currentAccessToken() async throws -> String
}
