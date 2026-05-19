//
//  SupabaseClient+NotificationPrefs.swift
//  LeafCore
//
//  Track 5 / S8 / T9 — best-effort server mirror of local `notification_prefs`.
//
//  Local store (M026 `notification_prefs` table) is the source of truth for
//  the UI toggle state. Server mirror is a hint for the `apns_push` Edge
//  Function (T5) to skip pushes for kinds the recipient has disabled —
//  saves a wasted APNs round-trip + reduces lock-screen noise.
//
//  Per T2 substrate (`20260519120000_s8_substrate.sql`):
//      CREATE TABLE notification_prefs (
//          pubkey TEXT NOT NULL,
//          pref_kind TEXT NOT NULL,
//          enabled BOOLEAN NOT NULL,
//          updated_at_ms BIGINT NOT NULL,
//          PRIMARY KEY (pubkey, pref_kind)
//      );
//      CREATE POLICY notification_prefs_self_rw ON notification_prefs
//          FOR ALL
//          USING (pubkey = auth.jwt() ->> 'pubkey')
//          WITH CHECK (pubkey = auth.jwt() ->> 'pubkey');
//
//  Failure is non-fatal — caller (`NotificationPrefsReader.setEnabled`)
//  swallows the throw via `try?`. The local row remains persisted; on next
//  setEnabled call we'll attempt the mirror again (no separate retry queue;
//  T6 retry queue is dm.markDone-specific).
//

import Foundation

extension SupabaseClient {

    /// T9 — UPSERT `notification_prefs` row keyed on `(pubkey, pref_kind)`.
    /// Uses `Prefer: resolution=merge-duplicates` so retries with the same PK
    /// silently overwrite instead of returning 409.
    ///
    /// The `pubkey` column value is sourced from the JWT `pubkey` claim
    /// (populated by T2 Auth Hook) — RLS `WITH CHECK pubkey = auth.jwt() ->>
    /// 'pubkey'` enforces match server-side.
    ///
    /// Throws `SupabaseError.identityClaimMissing` if the JWT carries no
    /// pubkey claim (Auth Hook race / pre-S2 token). Caller swallows.
    public func upsertNotificationPref(
        prefKind: String,
        enabled: Bool
    ) async throws {
        let session = try await ensureAuthenticated()
        guard let pubkeyClaim = session.pubkeyClaim, !pubkeyClaim.isEmpty else {
            throw SupabaseError.identityClaimMissing
        }
        let url = SupabaseEndpoint.notificationPrefsUpsert(baseURL: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in SupabaseEndpoint.postgrestUpsertHeaders(
            anonKey: anonKey, accessToken: session.accessToken
        ) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let nowMs = Int64(now().timeIntervalSince1970 * 1000)
        let body: [String: Any] = [
            "pubkey": pubkeyClaim,
            "pref_kind": prefKind,
            "enabled": enabled,
            "updated_at_ms": nowMs,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw SupabaseError.transport(reason: "upsertNotificationPref: \(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.transport(reason: "upsertNotificationPref: non-http")
        }
        // 201 Created — fresh row.
        // 200 / 204 — overwrite via merge-duplicates (Prefer: return=minimal collapses body).
        switch http.statusCode {
        case 200, 201, 204:
            return
        default:
            throw SupabaseError.fromStatus(http.statusCode, body: data)
        }
    }
}

extension SupabaseEndpoint {
    /// POST /rest/v1/notification_prefs — JWT-bearing UPSERT under
    /// `Prefer: resolution=merge-duplicates`. RLS gates `pubkey =
    /// auth.jwt() ->> 'pubkey'`.
    public static func notificationPrefsUpsert(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("rest/v1/notification_prefs")
    }
}
