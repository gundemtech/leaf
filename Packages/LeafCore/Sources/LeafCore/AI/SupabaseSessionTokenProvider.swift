import Foundation

/// AI-UI-4 — the concrete `AIInferenceAuthTokenProvider` for the AI-included
/// path: the app's live Supabase session supplies the relay-proxy bearer.
/// Two-step on purpose: `ensureAuthenticated()` owns the cold-start bootstrap
/// (persisted refresh token → session; pre-login substrate falls back to the
/// anonymous signup — the same trust model as every other Supabase call; the
/// account-login track turns the logged-out case into a `.unauthorized`
/// throw), then `ensureFreshSession()` owns the near-expiry guard — a cached
/// session is never handed out past its refresh window (protocol contract).
public struct SupabaseSessionTokenProvider: AIInferenceAuthTokenProvider {
  private let client: SupabaseClient

  public init(client: SupabaseClient) {
    self.client = client
  }

  public func currentAccessToken() async throws -> String {
    _ = try await client.ensureAuthenticated()
    return try await client.ensureFreshSession().accessToken
  }
}
