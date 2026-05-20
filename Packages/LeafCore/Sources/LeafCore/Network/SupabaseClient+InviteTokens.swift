//
//  SupabaseClient+InviteTokens.swift
//  LeafCore
//
//  M027 invite-redesign — REST wrappers over `invite_tokens` table on Supabase.
//
//  insertInviteToken — POST → 201 with row echoed (return=representation).
//                      RLS `invite_tokens_admin_write` gates by workspace admin
//                      + WITH CHECK enforces created_by_pubkey == JWT pubkey claim.
//
//  listInviteTokens  — GET → 200 [Row...]. RLS allows admin to list own workspace
//                      tokens (incl. expired/deleted for audit). Tightly-scoped to
//                      a single workspace_id filter; client-side filtering by
//                      isActive() happens at the UI layer.
//
//  markInviteTokenDeleted — PATCH deleted_at=now() → 200/204. RLS `admin_write`
//                           USING-clause filters non-admin callers; silent 0-rows
//                           outcome is mapped to `SupabaseError.noRowsAffected`
//                           via Content-Range header inspection.
//

import Foundation

extension SupabaseClient {

    /// POST a fresh invite token to Supabase. Returns the inserted row echoed
    /// by PostgREST `Prefer: return=representation` (T2 InviteToken passed in
    /// is local-shape; server adds `created_at` timestamp authoritatively).
    ///
    /// Throws `SupabaseError.fromStatus(409, ...)` on PK conflict (≈ never —
    /// 30^11 random space + checksum), `SupabaseError.forbidden` on RLS denial.
    public func insertInviteToken(_ token: InviteToken) async throws -> InviteToken {
        let session = try await ensureAuthenticated()
        let url = SupabaseEndpoint.inviteTokensInsert(baseURL: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in SupabaseEndpoint.postgrestInsertHeaders(
            anonKey: anonKey, accessToken: session.accessToken
        ) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.httpBody = try Self.encodeInviteTokenBody(token)

        let (data, response) = try await inviteTokensTransport(request, label: "insertInviteToken")
        guard response.statusCode == 201 else {
            throw SupabaseError.fromStatus(response.statusCode, body: data)
        }
        let rows = try Self.decodeInviteTokenRows(data)
        guard let first = rows.first else {
            throw SupabaseError.decoding(reason: "insertInviteToken: empty rows")
        }
        return first
    }

    /// GET all invite_tokens for the workspace (admin-only via RLS). Includes
    /// deleted/expired for audit view; caller filters via `InviteToken.isActive`.
    public func listInviteTokens(workspaceID: String) async throws -> [InviteToken] {
        let session = try await ensureAuthenticated()
        let url = SupabaseEndpoint.inviteTokensList(baseURL: baseURL, workspaceID: workspaceID)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in SupabaseEndpoint.authenticatedHeaders(
            anonKey: anonKey, accessToken: session.accessToken
        ) {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let (data, response) = try await inviteTokensTransport(request, label: "listInviteTokens")
        guard response.statusCode == 200 else {
            throw SupabaseError.fromStatus(response.statusCode, body: data)
        }
        return try Self.decodeInviteTokenRows(data)
    }

    /// PATCH `deleted_at` on a token row. RLS-gated to workspace admin (own
    /// workspace tokens only). Silent 0-rows → `SupabaseError.noRowsAffected`.
    public func markInviteTokenDeleted(code: String) async throws {
        let session = try await ensureAuthenticated()
        let url = SupabaseEndpoint.inviteTokensByCode(code, baseURL: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        for (k, v) in SupabaseEndpoint.postgrestPatchHeadersWithCount(
            anonKey: anonKey, accessToken: session.accessToken
        ) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "deleted_at": Self.iso8601(from: Date())
        ])

        let (data, response) = try await inviteTokensTransport(request, label: "markInviteTokenDeleted")
        guard response.statusCode == 204 || response.statusCode == 200 else {
            throw SupabaseError.fromStatus(response.statusCode, body: data)
        }
        try Self.assertInviteTokensContentRangeNonZero(response: response)
    }

    // MARK: - Wire encoding / decoding

    /// JSON body for POST. Sets all admin-controllable columns; server applies
    /// defaults for `created_at` (now()) and `used_count` (0).
    private static func encodeInviteTokenBody(_ token: InviteToken) throws -> Data {
        var dict: [String: Any] = [
            "code":              token.code,
            "workspace_id":      token.workspaceID,
            "created_by_pubkey": token.createdByPubkeyHex,
            "ttl_seconds":       token.ttlSeconds,
        ]
        if let label = token.label, !label.isEmpty {
            dict["label"] = label
        }
        if let expiresAt = token.expiresAt {
            dict["expires_at"] = iso8601(from: expiresAt)
        }
        if let maxUses = token.maxUses {
            dict["max_uses"] = maxUses
        }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    private static func decodeInviteTokenRows(_ data: Data) throws -> [InviteToken] {
        struct Row: Decodable {
            let code: String
            let workspace_id: String
            let created_by_pubkey: String
            let label: String?
            let ttl_seconds: Int
            let expires_at: String?
            let max_uses: Int?
            let used_count: Int
            let deleted_at: String?
            let created_at: String
        }
        let rows: [Row]
        do {
            rows = try JSONDecoder().decode([Row].self, from: data)
        } catch {
            throw SupabaseError.decoding(reason: "decodeInviteTokenRows: \(error)")
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]
        func parse(_ s: String) -> Date? {
            iso.date(from: s) ?? isoNoFrac.date(from: s)
        }
        return rows.map { row in
            InviteToken(
                code: row.code,
                workspaceID: row.workspace_id,
                createdByPubkeyHex: row.created_by_pubkey,
                label: row.label,
                ttlSeconds: row.ttl_seconds,
                expiresAt: row.expires_at.flatMap { parse($0) },
                maxUses: row.max_uses,
                usedCount: row.used_count,
                deletedAt: row.deleted_at.flatMap { parse($0) },
                createdAt: parse(row.created_at) ?? Date()
            )
        }
    }

    private static func iso8601(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Local replica of the workspaces-extension helper — detects
    /// `Content-Range: */0` silent-RLS-deny outcome on PATCH.
    private static func assertInviteTokensContentRangeNonZero(response: HTTPURLResponse) throws {
        guard let range = response.value(forHTTPHeaderField: "Content-Range") else {
            return
        }
        let parts = range.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let total = Int(parts[1]) else {
            return
        }
        if total == 0 {
            throw SupabaseError.noRowsAffected
        }
    }

    // MARK: - Transport

    private func inviteTokensTransport(
        _ request: URLRequest,
        label: String
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw SupabaseError.transport(reason: "\(label): \(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.transport(reason: "\(label): non-http")
        }
        return (data, http)
    }
}
