//
//  SupabaseClient+RealtimeAuth.swift
//  LeafCore
//
//  Track 5 / S7 — Realtime auth accessor for `RealtimeWebSocketDriver`.
//  Exposes the current valid access_token to the WS driver, which carries it
//  inside the phx_join payload (Supabase Realtime accepts JWT-in-payload, not
//  as a WebSocket upgrade header).
//
//  The access_token is short-lived (typically 1h); long-lived WS connections
//  (Phase D.5+) must refresh via existing `ensureAuthenticated` mechanism +
//  push a Phoenix `access_token` event to update the channel in-place
//  (see RealtimePhoenixFrame.accessTokenRefresh).
//

import Foundation

public extension SupabaseClient {
    /// Returns the current valid access_token from the auth session, or nil
    /// when no session exists (not signed in, expired, or in the middle of a
    /// bootstrap that hasn't completed). Non-throwing — caller treats nil as
    /// "skip Realtime connect, retry later".
    ///
    /// Distinct from `ensureAuthenticated()`: this is a passive read of the
    /// session that has already been established by SupabaseClient's existing
    /// HTTP flows. We do not trigger a bootstrap here — the WS driver should
    /// not block on auth; if there's no token yet, it waits for a future tick.
    func currentAccessToken() async -> String? {
        guard let session = currentSession() else { return nil }
        // Expiry guard: don't hand out tokens we know are stale. Realtime would
        // reject phx_join with status=error anyway, but failing fast here keeps
        // the caller's logs cleaner.
        guard session.expiresAt > now() else { return nil }
        return session.accessToken
    }
}
