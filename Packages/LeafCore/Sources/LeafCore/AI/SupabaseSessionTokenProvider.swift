import Foundation

/// AI-UI-4 — the concrete `AIInferenceAuthTokenProvider` for the AI-included
/// path: the app's live Supabase session supplies the relay-proxy bearer.
/// Two-step on purpose: `ensureAuthenticated()` owns the cold-start bootstrap
/// (persisted refresh token → session, or throw `.unauthorized` when logged
/// out), then `ensureFreshSession()` owns the near-expiry guard — the cached
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
