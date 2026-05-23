//
//  SupabaseClient+InviteTokens.swift
//  LeafCore
//
//  M027 invite-redesign — REST wrappers over `invite_tokens` table on Supabase.
//
//  insertInviteToken — M-II: POST → /functions/v1/insert_invite_token (Edge Fn).
//                      Edge Fn adds Idempotency-Key dedup. Returns 201
//                      { code, workspace_id, created_at }; we map into InviteToken
//                      (preserving caller-supplied fields; server's created_at
//                      replaces the local-clock value).
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

  /// POST a fresh invite token via `insert_invite_token` Edge Function (M-II).
  /// Idempotent — Idempotency-Key dedup on server makes retries safe.
  ///
  /// The Edge Function returns 201 { code, workspace_id, created_at }. We map
  /// this into an InviteToken by carrying forward all caller-supplied fields
  /// from the input token and replacing `createdAt` with the server's ISO
  /// authoritative timestamp. All other fields (label, ttlSeconds, expiresAt,
  /// maxUses, usedCount, deletedAt) are preserved from the input unchanged.
  ///
  /// - Throws: `SupabaseError.conflict` on 409 invite_token_exists (PK clash
  ///   — ≈ never given 30^11 random code space + checksum),
  ///   `SupabaseError.forbidden` on auth denial, transport errors otherwise.
  public func insertInviteToken(_ token: InviteToken) async throws -> InviteToken {
    let session = try await ensureAuthenticated()
    let url = SupabaseEndpoint.insertInviteTokenEdge(baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    for (k, v) in SupabaseEndpoint.authenticatedHeaders(
      anonKey: anonKey, accessToken: session.accessToken
    ) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    request.httpBody = try Self.encodeInviteTokenEdgeBody(token)

    let (data, response) = try await inviteTokensTransport(
      request, label: "insertInviteToken", retryable: true, refreshable: true,
      idempotent: true)
    guard response.statusCode == 201 else {
      throw SupabaseError.fromStatus(response.statusCode, body: data)
    }
    // Edge response: { code, workspace_id, created_at (ISO 8601) }.
    // Map into InviteToken: carry forward all input fields, replace createdAt
    // with the server's authoritative timestamp.
    struct EdgeRow: Decodable {
      let code: String
      let workspace_id: String
      let created_at: String
    }
    let row: EdgeRow
    do {
      row = try JSONDecoder().decode(EdgeRow.self, from: data)
    } catch {
      throw SupabaseError.decoding(reason: "insertInviteToken: \(error)")
    }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let isoNoFrac = ISO8601DateFormatter()
    isoNoFrac.formatOptions = [.withInternetDateTime]
    let serverCreatedAt =
      iso.date(from: row.created_at)
      ?? isoNoFrac.date(from: row.created_at)
      ?? Date()
    return InviteToken(
      code: row.code,
      workspaceID: row.workspace_id,
      createdByPubkeyHex: token.createdByPubkeyHex,
      label: token.label,
      ttlSeconds: token.ttlSeconds,
      expiresAt: token.expiresAt,
      maxUses: token.maxUses,
      usedCount: token.usedCount,
      deletedAt: token.deletedAt,
      createdAt: serverCreatedAt
    )
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

    let (data, response) = try await inviteTokensTransport(
      request, label: "listInviteTokens", retryable: true, refreshable: true)
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

    let (data, response) = try await inviteTokensTransport(
      request, label: "markInviteTokenDeleted", retryable: true, refreshable: true)
    guard response.statusCode == 204 || response.statusCode == 200 else {
      throw SupabaseError.fromStatus(response.statusCode, body: data)
    }
    try Self.assertInviteTokensContentRangeNonZero(response: response)
  }

  // MARK: - Wire encoding / decoding

  /// JSON body for `insert_invite_token` Edge Function (M-II).
  /// Body: { workspace_id, code, ttl_seconds, label?, expires_at?, max_uses?, created_at_ms }
  /// `created_at_ms` is included in the idempotency body hash but NOT stored by the server.
  private static func encodeInviteTokenEdgeBody(_ token: InviteToken) throws -> Data {
    var dict: [String: Any] = [
      "workspace_id": token.workspaceID,
      "code": token.code,
      "ttl_seconds": token.ttlSeconds,
      "created_at_ms": Int64(Date().timeIntervalSince1970 * 1000),
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

  /// JSON body for legacy PostgREST POST (kept for reference; no longer called).
  /// Sets all admin-controllable columns; server applies
  /// defaults for `created_at` (now()) and `used_count` (0).
  private static func encodeInviteTokenBody(_ token: InviteToken) throws -> Data {
    var dict: [String: Any] = [
      "code": token.code,
      "workspace_id": token.workspaceID,
      "created_by_pubkey": token.createdByPubkeyHex,
      "ttl_seconds": token.ttlSeconds,
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
    label: String,
    retryable: Bool = false,
    refreshable: Bool = false,
    idempotent: Bool = false
  ) async throws -> (Data, HTTPURLResponse) {
    try await performHTTP(
      request, retryable: retryable, refreshable: refreshable, idempotent: idempotent, label: label)
  }
}
