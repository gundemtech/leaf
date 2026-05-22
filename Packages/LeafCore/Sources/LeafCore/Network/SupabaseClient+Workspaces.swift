//
//  SupabaseClient+Workspaces.swift
//  LeafCore
//
//  Track 5 / S7 E.3 + E.4 — Workspace PATCH mutations via Supabase PostgREST.
//
//  Both PATCH methods hit /rest/v1/workspaces?id=eq.<id>. RLS policy (M025
//  `workspaces_creator_update`) gates writes to the workspace creator only —
//  non-admin callers receive 403 Forbidden mapped to `SupabaseError.forbidden`.
//
//  M027 follow-up — `insertWorkspace` POSTs the workspace row to the server
//  on local-creation time so the server-side `is_workspace_admin` RLS helper
//  (which queries `workspaces.created_by_pubkey`) returns true for every
//  subsequent admin operation (`invite_tokens` write, `invites` write, etc.).
//  Pre-M027 the workspaces table was server-side empty for any admin-created
//  workspace; S3 magic-link smoke gates G15/G16 were deferred to two-Mac
//  signed-build session, so this integration gap was not caught earlier.
//
//  Validation duplicates `WorkspaceService.updateName` for defence-in-depth
//  so that the network call is never fired with an invalid payload even if the
//  caller skips the local-service layer.
//

import Foundation

extension SupabaseClient {

  // MARK: - M027 — insertWorkspace (admin self-insert)

  /// POST a freshly-created workspace row to Supabase. RLS allows the
  /// caller iff the JWT `pubkey` claim matches `created_by_pubkey` in the
  /// body — defence-in-depth against impersonation. Server-side
  /// `workspaces_name_per_admin_unique` constraint maps a duplicate name
  /// (same admin pubkey, same name) to a 409 → `SupabaseError.conflict`.
  ///
  /// - Parameters:
  ///   - id: UUID of the workspace row (same value used in local
  ///     `workspaces.id`; UUID string in canonical lowercase form).
  ///   - name: display name. Trimmed before sending; ≤80 chars after trim
  ///     (mirrors `WorkspaceService` validation).
  ///   - createdByPubkey: admin's X25519 pubkey hex (64 lowercase hex chars).
  /// - Throws: `LeafError.invalidPayload` on empty/too-long name,
  ///   `SupabaseError.conflict` on UNIQUE(created_by_pubkey, name) violation,
  ///   `SupabaseError.forbidden` on RLS denial, transport errors otherwise.
  public func insertWorkspace(
    id: String,
    name: String,
    createdByPubkey: String
  ) async throws {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 80 else {
      throw LeafError.invalidPayload
    }
    let session = try await ensureAuthenticated()
    let url = SupabaseEndpoint.workspacesInsert(baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    for (k, v) in SupabaseEndpoint.postgrestInsertHeaders(
      anonKey: anonKey, accessToken: session.accessToken
    ) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    let body: [String: Any] = [
      "id": id,
      "name": trimmed,
      "created_by_pubkey": createdByPubkey,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await workspacesTransport(
      request, label: "insertWorkspace", retryable: false)
    guard response.statusCode == 201 else {
      throw SupabaseError.fromStatus(response.statusCode, body: data)
    }
  }

  // MARK: - E.3: patchWorkspaceName

  /// PATCH workspace display name on Supabase.
  ///
  /// - Parameters:
  ///   - id: UUID of the workspace row to update.
  ///   - name: New display name. Trimmed before sending; must be non-empty
  ///     and ≤ 80 characters after trim, otherwise throws `LeafError.invalidPayload`
  ///     without firing a network call.
  /// - Throws: `LeafError.invalidPayload` on empty / too-long name,
  ///   `SupabaseError.forbidden` on RLS denial, `SupabaseError.transport` on
  ///   network failure, or any other `SupabaseError` for non-2xx responses.
  ///
  /// Caller should call `WorkspaceService.updateName` first to persist the
  /// change locally, then call this to sync with Supabase.
  public func patchWorkspaceName(id: String, name: String) async throws {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 80 else {
      throw LeafError.invalidPayload
    }
    let session = try await ensureAuthenticated()
    let url = SupabaseEndpoint.workspaceByID(id, baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "PATCH"
    for (k, v) in SupabaseEndpoint.postgrestPatchHeadersWithCount(
      anonKey: anonKey, accessToken: session.accessToken
    ) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: ["name": trimmed])

    let (data, response) = try await workspacesTransport(
      request, label: "patchWorkspaceName", retryable: true)
    // PostgREST PATCH returns 204 No Content on success when Prefer: return=minimal.
    guard response.statusCode == 204 || response.statusCode == 200 else {
      throw SupabaseError.fromStatus(response.statusCode, body: data)
    }
    // S7 Stage 6 fix C-I9 — detect silent-0-row RLS-deny outcomes.
    try Self.assertContentRangeNonZero(response: response)
  }

  // MARK: - E.4: softDeleteWorkspace

  /// PATCH `deleted_at_ms` on the Supabase workspace row (soft-delete).
  ///
  /// - Parameter id: UUID of the workspace row to soft-delete.
  /// - Throws: `SupabaseError.forbidden` on RLS denial, `SupabaseError.transport`
  ///   on network failure, or any other `SupabaseError` for non-2xx responses.
  ///
  /// Call `WorkspaceService.softDelete(workspaceID:at:)` after this succeeds
  /// to wipe the local SQLCipher rows and keystore directory.
  public func softDeleteWorkspace(id: String) async throws {
    let session = try await ensureAuthenticated()
    let url = SupabaseEndpoint.workspaceByID(id, baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "PATCH"
    for (k, v) in SupabaseEndpoint.postgrestPatchHeadersWithCount(
      anonKey: anonKey, accessToken: session.accessToken
    ) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    request.httpBody = try JSONSerialization.data(withJSONObject: ["deleted_at_ms": nowMs])

    let (data, response) = try await workspacesTransport(
      request, label: "softDeleteWorkspace", retryable: true)
    guard response.statusCode == 204 || response.statusCode == 200 else {
      throw SupabaseError.fromStatus(response.statusCode, body: data)
    }
    // S7 Stage 6 fix C-I9 — detect silent-0-row RLS-deny outcomes.
    try Self.assertContentRangeNonZero(response: response)
  }

  /// PostgREST's `Prefer: count=exact` adds a `Content-Range` header in the
  /// form `0-(N-1)/N` on success, or `*/0` when zero rows matched the
  /// `?id=eq.<uuid>` filter (e.g., the RLS USING-clause filtered the row
  /// out for this caller). We throw `.noRowsAffected` in the latter case so
  /// callers can distinguish "looks like success but server didn't actually
  /// mutate anything" from genuine success.
  ///
  /// Header missing → treat as success (older PostgREST versions or
  /// non-Supabase mocks may not include the header).
  private static func assertContentRangeNonZero(response: HTTPURLResponse) throws {
    guard let range = response.value(forHTTPHeaderField: "Content-Range") else {
      return
    }
    // Shape examples: "0-0/1", "*/0", "0-9/10".
    // Affected count is the suffix after `/`.
    let parts = range.split(separator: "/", maxSplits: 1)
    guard parts.count == 2, let total = Int(parts[1]) else {
      return  // unparseable → defensive success
    }
    if total == 0 {
      throw SupabaseError.noRowsAffected
    }
  }

  // MARK: - Private transport helper (local to this extension)

  /// Mirrors the pattern from `SupabaseClient+DirectMessages.swift` and
  /// `SupabaseClient+TeamEvents.swift` — each extension owns its private transport
  /// wrapper to avoid cross-file visibility issues with the actor's internals.
  private func workspacesTransport(
    _ request: URLRequest,
    label: String,
    retryable: Bool = false
  ) async throws -> (Data, HTTPURLResponse) {
    try await performHTTP(request, retryable: retryable, label: label)
  }
}
